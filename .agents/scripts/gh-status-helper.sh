#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# gh-status-helper.sh — Query GitHub Statuspage API for platform health
#
# Use case: distinguish "GitHub is down" from "our code is broken" during
# pulse degradation incidents. Without this helper, an operator has to
# manually visit githubstatus.com — and a passing `gh auth status` plus
# `gh api rate_limit` are both consistent with a silently-degrading search
# backend (the 2026-04-27 incident pattern).
#
# Usage:
#   gh-status-helper.sh check                 # one-line summary; exit 0/1/2
#   gh-status-helper.sh check-actions         # Actions incident circuit-breaker signal
#   gh-status-helper.sh incidents             # list active incidents
#   gh-status-helper.sh correlate             # markdown block for issue comments
#   gh-status-helper.sh check --json          # JSON output for programmatic callers
#   gh-status-helper.sh check --no-cache      # bypass 60s response cache
#
# Exit codes:
#   0  operational                            (none / minor)
#   1  degraded                               (major)
#   2  outage                                 (critical)
#
# API: https://www.githubstatus.com/api/v2/
#   - status.json: overall indicator (none|minor|major|critical) + description
#   - incidents/unresolved.json: active incident list with components
#
# Cache: ~/.aidevops/cache/gh-status-{status,incidents}.json (60s freshness).
# Statuspage rate limit ~100 req/min/IP; cache prevents hammering during
# tight diagnostic loops.
#
# Mock interface (for tests):
#   AIDEVOPS_GH_STATUS_MOCK_DIR=/tmp/mocks gh-status-helper.sh check
#   When set, helper reads status.json + incidents.json from that dir
#   instead of curl. Used by tests/test-gh-status-helper.sh.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit
# shellcheck source=./shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

set -euo pipefail

readonly STATUS_API_BASE="https://www.githubstatus.com/api/v2"
readonly STATUS_URL="${STATUS_API_BASE}/status.json"
readonly INCIDENTS_URL="${STATUS_API_BASE}/incidents/unresolved.json"
readonly CACHE_DIR="${AIDEVOPS_GH_STATUS_CACHE_DIR:-$HOME/.aidevops/cache}"
readonly CACHE_STATUS="${CACHE_DIR}/gh-status-status.json"
readonly CACHE_INCIDENTS="${CACHE_DIR}/gh-status-incidents.json"
readonly CACHE_MAX_AGE_SECONDS="${AIDEVOPS_GH_STATUS_CACHE_TTL:-60}"

# Indicator literal used by jq fallbacks and case branches.
readonly INDICATOR_UNKNOWN="unknown"
readonly STATUS_NETWORK_FAILURE="network_failure"
readonly ACTIONS_COMPONENT="Actions"

# CLI flag state
ARG_JSON=0
ARG_NO_CACHE=0

# ----------------------------------------------------------------------
# Cache helpers
# ----------------------------------------------------------------------

# _cache_age <file> -> prints age in seconds, or 99999 if missing.
_cache_age() {
	local file="$1"
	[[ ! -f "$file" ]] && {
		printf '99999\n'
		return 0
	}
	local now mtime
	now=$(date +%s)
	mtime=$(_file_mtime_epoch "$file")
	if [[ "$mtime" -eq 0 ]]; then
		printf '99999\n'
		return 0
	fi
	printf '%d\n' "$((now - mtime))"
	return 0
}

# _fetch <url> <cache-file> — populates cache from URL or mock dir.
# Honours AIDEVOPS_GH_STATUS_MOCK_DIR for tests; otherwise curls the URL.
_fetch() {
	local url="$1"
	local cache_file="$2"

	if [[ -n "${AIDEVOPS_GH_STATUS_MOCK_DIR:-}" ]]; then
		local mock_name
		mock_name=$(basename "$url")
		local mock_path="${AIDEVOPS_GH_STATUS_MOCK_DIR}/${mock_name}"
		if [[ -f "$mock_path" ]]; then
			cp "$mock_path" "$cache_file"
			return 0
		fi
		printf 'gh-status-helper: mock file not found: %s\n' "$mock_path" >&2
		return 1
	fi

	mkdir -p "$(dirname "$cache_file")"
	# 10s connect timeout, 15s total. Statuspage is normally <500ms.
	if ! curl --silent --show-error --location --max-time 15 \
		--connect-timeout 10 \
		--output "$cache_file" \
		"$url" 2>/dev/null; then
		return 1
	fi
	# Validate the response is JSON before claiming success.
	if ! jq empty "$cache_file" 2>/dev/null; then
		rm -f "$cache_file"
		return 1
	fi
	return 0
}

# _ensure_cache <url> <cache-file> — refresh cache if older than TTL or missing.
_ensure_cache() {
	local url="$1"
	local cache_file="$2"
	local age
	age=$(_cache_age "$cache_file")
	if [[ "$ARG_NO_CACHE" -eq 1 ]] || [[ "$age" -gt "$CACHE_MAX_AGE_SECONDS" ]]; then
		_fetch "$url" "$cache_file" || return 1
	fi
	return 0
}

# ----------------------------------------------------------------------
# Subcommands
# ----------------------------------------------------------------------

_print_component_status_json() {
	local status="$1"
	local component="${2:-}"
	local reason="${3:-}"
	local impact="${4:-}"
	local incident="${5:-}"
	jq -n \
		--arg status "$status" \
		--arg component "$component" \
		--arg reason "$reason" \
		--arg impact "$impact" \
		--arg incident "$incident" '
		{status:$status}
		+ (if $component == "" then {} else {component:$component} end)
		+ (if $reason == "" then {} else {reason:$reason} end)
		+ (if $impact == "" then {} else {impact:$impact} end)
		+ (if $incident == "" then {} else {incident:$incident} end)'
	return 0
}

_actions_incidents_json() {
	local cache_file="$1"
	jq -c '
		def is_object: type == "object";
		def valid_component:
			is_object and (.name | type) == "string";
		def valid_incident:
			is_object
			and (.components | type) == "array"
			and all(.components[]; valid_component);
		if (is_object | not)
			or (.incidents | type) != "array"
			or (all(.incidents[]; valid_incident) | not)
		then error("invalid incidents schema")
		else [.incidents[] | select(any(.components[]; (.name | ascii_downcase) == "actions"))]
		end' "$cache_file" 2>/dev/null
	return $?
}

# cmd_check — fetch overall status, classify, print summary, set exit code.
cmd_check() {
	if ! _ensure_cache "$STATUS_URL" "$CACHE_STATUS"; then
		if [[ "$ARG_JSON" -eq 1 ]]; then
			printf '{"status":"%s","reason":"%s"}\n' "$INDICATOR_UNKNOWN" "$STATUS_NETWORK_FAILURE"
		else
			printf '%s — could not reach Statuspage API\n' "$INDICATOR_UNKNOWN" >&2
		fi
		return 3
	fi

	local indicator description
	indicator=$(jq -r --arg fallback "$INDICATOR_UNKNOWN" '.status.indicator // $fallback' "$CACHE_STATUS")
	description=$(jq -r --arg fallback "$INDICATOR_UNKNOWN" '.status.description // $fallback' "$CACHE_STATUS")

	# Map indicator → exit code per Statuspage convention:
	#   none    → 0 (operational)
	#   minor   → 0 (operational, sub-component degradation only)
	#   major   → 1 (degraded — feature outage)
	#   critical → 2 (outage)
	local exit_code label
	case "$indicator" in
	none | minor)
		exit_code=0
		label="operational"
		;;
	major)
		exit_code=1
		label="degraded"
		;;
	critical)
		exit_code=2
		label="outage"
		;;
	*)
		exit_code=3
		label="$INDICATOR_UNKNOWN"
		;;
	esac

	if [[ "$ARG_JSON" -eq 1 ]]; then
		jq -n \
			--arg label "$label" \
			--arg indicator "$indicator" \
			--arg description "$description" \
			'{status: $label, indicator: $indicator, description: $description}'
	else
		printf '%s — %s\n' "$label" "$description"
	fi
	return "$exit_code"
}

# cmd_check_actions — report whether an unresolved incident affects Actions.
# This component-specific signal is intentionally stricter than the overall
# status indicator: even a minor platform incident can make CI retries harmful.
cmd_check_actions() {
	if ! _ensure_cache "$INCIDENTS_URL" "$CACHE_INCIDENTS"; then
		if [[ "$ARG_JSON" -eq 1 ]]; then
			_print_component_status_json "$INDICATOR_UNKNOWN" "$ACTIONS_COMPONENT" "$STATUS_NETWORK_FAILURE"
		else
			printf '%s — could not reach Statuspage API\n' "$INDICATOR_UNKNOWN" >&2
		fi
		return 3
	fi

	local actions_incidents="" incident_count="" impact="none" incident_name=""
	actions_incidents=$(_actions_incidents_json "$CACHE_INCIDENTS") || return 3
	incident_count=$(printf '%s' "$actions_incidents" | jq 'length' 2>/dev/null) || return 3
	[[ "$incident_count" =~ ^[0-9]+$ ]] || return 3
	if [[ "$incident_count" -gt 0 ]]; then
		impact=$(printf '%s' "$actions_incidents" | jq -r --arg unknown "$INDICATOR_UNKNOWN" '.[0].impact // $unknown') || return 3
		incident_name=$(printf '%s' "$actions_incidents" | jq -r '.[0].name // "GitHub Actions incident"') || return 3
		if [[ "$ARG_JSON" -eq 1 ]]; then
			_print_component_status_json "incident" "$ACTIONS_COMPONENT" "" "$impact" "$incident_name"
		else
			printf 'incident — Actions affected by %s (%s)\n' "$incident_name" "$impact"
		fi
		return 1
	fi

	if [[ "$ARG_JSON" -eq 1 ]]; then
		_print_component_status_json "operational" "$ACTIONS_COMPONENT"
	else
		printf 'operational — no unresolved Actions incident\n'
	fi
	return 0
}

# cmd_incidents — list unresolved incidents.
cmd_incidents() {
	if ! _ensure_cache "$INCIDENTS_URL" "$CACHE_INCIDENTS"; then
		if [[ "$ARG_JSON" -eq 1 ]]; then
			printf '{"incidents":[],"reason":"%s"}\n' "$STATUS_NETWORK_FAILURE"
		else
			printf '%s — could not reach Statuspage API\n' "$INDICATOR_UNKNOWN" >&2
		fi
		return 3
	fi

	if [[ "$ARG_JSON" -eq 1 ]]; then
		jq '{incidents: [.incidents[]? | {name, impact, started_at, latest_update: (.incident_updates[0].body? // ""), components: [.components[]?.name]}]}' "$CACHE_INCIDENTS"
	else
		# Human-readable listing. Empty list = healthy.
		local count
		count=$(jq '.incidents | length' "$CACHE_INCIDENTS")
		if [[ "$count" -eq 0 ]]; then
			printf 'No active incidents.\n'
			return 0
		fi
		jq -r '.incidents[] | "[\(.impact)] \(.name)\n  started: \(.started_at)\n  components: \([.components[].name] | join(", "))\n  latest: \(.incident_updates[0].body // "")\n"' "$CACHE_INCIDENTS"
	fi
	return 0
}

# cmd_correlate — produce a markdown block suitable for `gh issue comment`.
# Format mirrors the manual correlation comments posted during the
# 2026-04-27 incident: status label + active-incident summary.
cmd_correlate() {
	if ! _ensure_cache "$STATUS_URL" "$CACHE_STATUS"; then
		printf '> GitHub Statuspage unreachable from this runner — could not correlate symptom timestamp with platform state.\n'
		return 3
	fi
	_ensure_cache "$INCIDENTS_URL" "$CACHE_INCIDENTS" || true

	local indicator description timestamp
	indicator=$(jq -r --arg fallback "$INDICATOR_UNKNOWN" '.status.indicator // $fallback' "$CACHE_STATUS")
	description=$(jq -r --arg fallback "$INDICATOR_UNKNOWN" '.status.description // $fallback' "$CACHE_STATUS")
	timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

	printf '<!-- aidevops:gh-status-correlation -->\n'
	# shellcheck disable=SC2016 # backticks are markdown, not command substitution
	printf '**GitHub platform state at %s:** `%s` — %s\n\n' "$timestamp" "$indicator" "$description"

	if [[ -f "$CACHE_INCIDENTS" ]]; then
		local count
		count=$(jq '.incidents | length' "$CACHE_INCIDENTS")
		if [[ "$count" -gt 0 ]]; then
			printf 'Active incidents:\n\n'
			jq -r '.incidents[]? | "- **[\(.impact)]** \(.name) — components: \([.components[]?.name] | join(", ")) (started \(.started_at))"' "$CACHE_INCIDENTS"
			printf '\n'
		fi
	fi

	printf 'Source: <https://www.githubstatus.com/>\n'
	return 0
}

# ----------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------

print_usage() {
	cat <<'EOF'
gh-status-helper.sh — Query GitHub Statuspage API for platform health

Usage:
  gh-status-helper.sh check        [--json] [--no-cache]
  gh-status-helper.sh check-actions [--json] [--no-cache]
  gh-status-helper.sh incidents    [--json] [--no-cache]
  gh-status-helper.sh correlate              [--no-cache]
  gh-status-helper.sh -h | --help

Exit codes (check):
  0  operational (none/minor)
  1  degraded (major)
  2  outage (critical)
  3  unknown / network failure

Exit codes (check-actions): 0 operational, 1 active incident, 3 unknown.

Cache: ~/.aidevops/cache/gh-status-*.json (60s TTL, override via
AIDEVOPS_GH_STATUS_CACHE_TTL).

Tests can stub the API by setting AIDEVOPS_GH_STATUS_MOCK_DIR to a
directory containing status.json and incidents/unresolved.json.
EOF
	return 0
}

main() {
	# Parse global flags first; remaining args dispatched as subcommand.
	local subcommand=""
	while [[ $# -gt 0 ]]; do
		local arg="$1"
		case "$arg" in
		--json) ARG_JSON=1 ;;
		--no-cache) ARG_NO_CACHE=1 ;;
		-h | --help)
			print_usage
			return 0
			;;
		check | check-actions | incidents | correlate)
			subcommand="$arg"
			;;
		*)
			printf 'gh-status-helper: unknown argument: %s\n' "$arg" >&2
			print_usage >&2
			return 64
			;;
		esac
		shift
	done

	case "$subcommand" in
	check) cmd_check ;;
	check-actions) cmd_check_actions ;;
	incidents) cmd_incidents ;;
	correlate) cmd_correlate ;;
	"")
		print_usage >&2
		return 64
		;;
	*)
		printf 'gh-status-helper: internal dispatch error: %s\n' "$subcommand" >&2
		return 70
		;;
	esac
}

main "$@"
