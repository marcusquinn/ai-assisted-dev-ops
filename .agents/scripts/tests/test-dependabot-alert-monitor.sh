#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPT_DIR}/.."
TEST_TMP="$(mktemp -d "${TMPDIR:-/tmp}/dependabot-alert-monitor-XXXXXX")"

cleanup() {
	rm -rf "$TEST_TMP" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

fail() {
	local message="$1"
	printf 'FAIL: %s\n' "$message" >&2
	exit 1
	return 1
}

write_repos_json() {
	local repos_json="$1"
	cat >"$repos_json" <<'JSON'
{
  "initialized_repos": [
    {"slug": "owner/project", "path": "/tmp/project", "pulse": true, "role": "maintainer"},
    {"slug": "owner/disabled", "path": "/tmp/disabled", "pulse": true, "dependabot_alert_monitor": false},
    {"slug": "owner/contributor", "path": "/tmp/contributor", "pulse": true, "role": "contributor"},
    {"slug": "owner/local", "path": "/tmp/local", "pulse": true, "local_only": true}
  ]
}
JSON
	return 0
}

write_fanout_repos_json() {
	local repos_json="$1"
	cat >"$repos_json" <<'JSON'
{
  "initialized_repos": [
    {"slug": "owner/first", "pulse": true, "role": "maintainer"},
    {"slug": "owner/second", "pulse": true, "role": "maintainer"},
    {"slug": "owner/third", "pulse": true, "role": "maintainer"}
  ]
}
JSON
	return 0
}

TEST_CORE_REMAINING=5000
TEST_ALERT_FAILURE_REPO=""
TEST_ALERT_FAILURE_MESSAGE=""

gh() {
	local command="${1:-}"
	shift || true
	case "$command" in
	api)
		local endpoint=""
		local jq_expr=""
		while [[ $# -gt 0 ]]; do
			case "$1" in
			--paginate|--slurp)
				shift
				;;
			--jq)
				jq_expr="${2:-}"
				shift 2
				;;
			*)
				[[ -n "$endpoint" ]] || endpoint="$1"
				shift
				;;
			esac
		done
		printf '%s\n' "$endpoint" >>"${TEST_TMP}/api.log"
		printf '%s|%s\n' "${AIDEVOPS_GH_ROUTE_DECISION:-unset}" "$endpoint" >>"${TEST_TMP}/routes.log"
		case "$endpoint" in
		rate_limit)
			if [[ "$jq_expr" == *'.resources.core.remaining'* ]]; then
				printf '%s\n' "$TEST_CORE_REMAINING"
			else
				printf '{"resources":{"core":{"remaining":%s}}}\n' "$TEST_CORE_REMAINING"
			fi
			;;
		repos/*/dependabot/alerts*)
			local repo_slug="${endpoint#repos/}"
			repo_slug="${repo_slug%%/dependabot/alerts*}"
			if [[ -n "$TEST_ALERT_FAILURE_REPO" && "$repo_slug" == "$TEST_ALERT_FAILURE_REPO" ]]; then
				printf '%s\n' "$TEST_ALERT_FAILURE_MESSAGE" >&2
				return 1
			fi
			case "$repo_slug" in
			owner/project)
				cat <<'JSON'
[[
  {"state":"open","dependency":{"package":{"name":"litellm","ecosystem":"pip"},"manifest_path":"requirements.txt"},"security_advisory":{"severity":"high"},"security_vulnerability":{"first_patched_version":{"identifier":"1.84.0"}}},
  {"state":"open","dependency":{"package":{"name":"litellm","ecosystem":"pip"},"manifest_path":"requirements-lock.txt"},"security_advisory":{"severity":"critical"},"security_vulnerability":{"first_patched_version":{"identifier":"1.84.0"}}},
  {"state":"open","dependency":{"package":{"name":"diskcache","ecosystem":"pip"},"manifest_path":"requirements.txt"},"security_advisory":{"severity":"medium"},"security_vulnerability":{"first_patched_version":null}}
]]
JSON
				;;
			*) printf '[]\n' ;;
			esac
			;;
		*)
			printf '[]\n'
			;;
		esac
		;;
	issue)
		local subcommand="${1:-}"
		shift || true
		case "$subcommand" in
		list)
			local search=""
			while [[ $# -gt 0 ]]; do
				case "$1" in
				--search)
					search="$2"
					shift 2
					;;
				*)
					shift
					;;
				esac
			done
			local title_search="${search#\"}"
			title_search="${title_search%%\" in:title*}"
			if [[ -f "${TEST_TMP}/issues.log" ]] && grep -Fq "$title_search" "${TEST_TMP}/issues.log"; then
				printf '1\n'
			else
				printf '\n'
			fi
			;;
		*)
			return 1
			;;
		esac
		;;
	label)
		return 0
		;;
	*)
		return 1
		;;
	esac
	return 0
}

gh_create_issue() {
	local title=""
	local repo=""
	local body_file=""
	local labels=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="$2"
			shift 2
			;;
		--title)
			title="$2"
			shift 2
			;;
		--body-file)
			body_file="$2"
			shift 2
			;;
		--label)
			labels="${labels}${labels:+,}$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	printf '%s|%s|%s\n' "$repo" "$title" "$labels" >>"${TEST_TMP}/issues.log"
	if [[ -n "$body_file" ]]; then
		cp "$body_file" "${TEST_TMP}/body-$(wc -l <"${TEST_TMP}/issues.log" | tr -d ' ').md"
	fi
	printf 'https://github.com/%s/issues/%s\n' "$repo" "$(wc -l <"${TEST_TMP}/issues.log" | tr -d ' ')"
	return 0
}

export -f gh
export -f gh_create_issue

HOME="${TEST_TMP}/home"
LOGFILE="${TEST_TMP}/pulse.log"
DEPENDABOT_ALERT_MONITOR_STATE_DIR="${TEST_TMP}/state"
export HOME LOGFILE DEPENDABOT_ALERT_MONITOR_STATE_DIR

# shellcheck source=../dependabot-alert-monitor.sh
source "${SCRIPTS_DIR}/dependabot-alert-monitor.sh"

# shared-constants.sh defines the production gh_create_issue wrapper; restore
# the test double after sourcing so no real GitHub writes can occur.
gh_create_issue() {
	local title=""
	local repo=""
	local body_file=""
	local labels=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
		--repo)
			repo="$2"
			shift 2
			;;
		--title)
			title="$2"
			shift 2
			;;
		--body-file)
			body_file="$2"
			shift 2
			;;
		--label)
			labels="${labels}${labels:+,}$2"
			shift 2
			;;
		*)
			shift
			;;
		esac
	done
	printf '%s|%s|%s\n' "$repo" "$title" "$labels" >>"${TEST_TMP}/issues.log"
	if [[ -n "$body_file" ]]; then
		cp "$body_file" "${TEST_TMP}/body-$(wc -l <"${TEST_TMP}/issues.log" | tr -d ' ').md"
	fi
	printf 'https://github.com/%s/issues/%s\n' "$repo" "$(wc -l <"${TEST_TMP}/issues.log" | tr -d ' ')"
	return 0
}

repos_json="${TEST_TMP}/repos.json"
write_repos_json "$repos_json"

dependabot_alert_monitor_scan_repos "$repos_json" "0" || fail "scan failed"

if ! grep -q '^dependabot-alert-monitor-core-budget-rest|rate_limit$' "${TEST_TMP}/routes.log"; then
	fail "core-budget preflight was not explicitly attributed"
fi
if ! grep -q '^dependabot-alert-monitor-alerts-rest|repos/owner/project/dependabot/alerts' "${TEST_TMP}/routes.log"; then
	fail "Dependabot alert reads were not explicitly attributed"
fi

issue_count="$(wc -l <"${TEST_TMP}/issues.log" | tr -d ' ')"
[[ "$issue_count" == "2" ]] || fail "expected 2 grouped issues, got ${issue_count}"

if ! grep -q 'owner/project|Remediate dependency alert: litellm (pip)|.*auto-dispatch.*origin:worker.*tier:standard' "${TEST_TMP}/issues.log"; then
	fail "patched alert group did not create worker-ready remediation issue"
fi

if ! grep -q 'owner/project|Investigate dependency alert: diskcache (pip)|.*needs-investigation' "${TEST_TMP}/issues.log"; then
	fail "no-patch alert group did not create investigation issue"
fi

if grep -q 'owner/disabled\|owner/contributor\|owner/local' "${TEST_TMP}/api.log"; then
	fail "non-managed/opted-out repos were scanned"
fi

if grep -Eqi '(CVE-[0-9]|GHSA-|/security/dependabot)' "${TEST_TMP}/issues.log" "${TEST_TMP}"/body-*.md; then
	fail "issue output leaked advisory identifiers or alert URLs"
fi

dependabot_alert_monitor_scan_repos "$repos_json" "0" || fail "second scan failed"
second_issue_count="$(wc -l <"${TEST_TMP}/issues.log" | tr -d ' ')"
[[ "$second_issue_count" == "2" ]] || fail "state dedupe created duplicate issues"

# Low budget must stop before the first repository alert request.
: >"${TEST_TMP}/api.log"
TEST_CORE_REMAINING=251
dependabot_alert_monitor_scan_repos "$repos_json" "1" || fail "low-budget scan failed"
if grep -q '/dependabot/alerts' "${TEST_TMP}/api.log"; then
	fail "low-budget preflight still entered repository fanout"
fi
if ! grep -q 'core budget insufficient for Dependabot fanout' "$LOGFILE"; then
	fail "low-budget preflight did not record a decision"
fi

fanout_repos_json="${TEST_TMP}/fanout-repos.json"
write_fanout_repos_json "$fanout_repos_json"
TEST_CORE_REMAINING=5000

# A primary/secondary rate-limit response stops the repository loop immediately.
: >"${TEST_TMP}/api.log"
TEST_ALERT_FAILURE_REPO="owner/first"
TEST_ALERT_FAILURE_MESSAGE="gh: API rate limit exceeded (HTTP 403)"
dependabot_alert_monitor_scan_repos "$fanout_repos_json" "1" || fail "rate-limited fanout scan failed"
if grep -q 'repos/owner/second/dependabot/alerts' "${TEST_TMP}/api.log"; then
	fail "rate-limited fanout continued to the second repository"
fi
if ! grep -q 'stopping Dependabot fanout after rate-limit response from owner/first' "$LOGFILE"; then
	fail "rate-limited fanout did not log its stop decision"
fi

# Permission/configuration failures remain repo-local and do not suppress peers.
: >"${TEST_TMP}/api.log"
TEST_ALERT_FAILURE_MESSAGE="gh: Dependabot alerts are disabled (HTTP 403)"
dependabot_alert_monitor_scan_repos "$fanout_repos_json" "1" || fail "repo-local failure scan failed"
if ! grep -q 'repos/owner/second/dependabot/alerts' "${TEST_TMP}/api.log"; then
	fail "non-rate-limit repository failure stopped the remaining fanout"
fi

printf 'PASS dependabot alert monitor grouped managed repo alerts\n'
