#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERSON_LIB="${SCRIPT_DIR}/../contributor-activity-helper-person.sh"
DASHBOARD_LIB="${SCRIPT_DIR}/../stats-health-dashboard-data.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PASS=0
FAIL=0

pass() {
	local name="$1"
	printf '[PASS] %s\n' "$name"
	PASS=$((PASS + 1))
	return 0
}

fail() {
	local name="$1"
	local detail="$2"
	printf '[FAIL] %s\n       %s\n' "$name" "$detail"
	FAIL=$((FAIL + 1))
	return 0
}

define_timeout_sec_mock() {
	timeout_sec() {
		local _seconds="${1:-}"
		[[ -n "$_seconds" ]] || return 124
		shift
		"$@"
		return $?
	}
	return 0
}

test_failed_queries_are_partial() {
	local name="person stats classifies Search API failures as partial"
	local stderr_file="${TMP_DIR}/query-failure.stderr"
	local output
	output=$(
		# shellcheck source=../contributor-activity-helper-person.sh
		source "$PERSON_LIB"
		_person_stats_gh_api() {
			local endpoint="${1:-}"
			if [[ "$endpoint" == "rate_limit" ]]; then
				printf '%s' '30'
				return 0
			fi
			return 1
		}
		_person_stats_query_github "alice" "owner/repo" "2026-01-01" 2>"$stderr_file"
	)
	if grep -q '^PARTIAL=true$' "$stderr_file" && [[ "$output" == *'"issues_created":0'* ]]; then
		pass "$name"
	else
		fail "$name" "failed Search API queries were rendered as complete zero data"
	fi
	return 0
}

test_cross_repo_all_zero_semantics() {
	local name="cross-repo stats distinguish failed collection from true zero"
	local zero_json='[{"login":"alice","issues_created":0,"prs_created":0,"prs_merged":0,"commented_on":0}]'
	local partial_output true_zero_output
	partial_output=$(
		# shellcheck source=../contributor-activity-helper-person.sh
		source "$PERSON_LIB"
		_cross_repo_person_stats_aggregate "$zero_json" markdown month 3 true
	)
	true_zero_output=$(
		# shellcheck source=../contributor-activity-helper-person.sh
		source "$PERSON_LIB"
		_cross_repo_person_stats_aggregate "$zero_json" markdown month 3 false
	)
	if [[ "$partial_output" == *"unavailable or incomplete"* && "$partial_output" != *"| Contributor |"* && "$true_zero_output" == *"No GitHub activity across 3 repos"* && "$true_zero_output" != *"unavailable"* ]]; then
		pass "$name"
	else
		fail "$name" "all-zero failed and successful collections were not rendered distinctly"
	fi
	return 0
}

test_cross_repo_collection_failures_are_partial() {
	local name="cross-repo stats propagate repository collection failures"
	local repo_dir="${TMP_DIR}/collection-failure-repo"
	local stderr_file="${TMP_DIR}/collection-failure.stderr"
	local output
	mkdir -p "${repo_dir}/.git"
	output=$(
		EX_PARTIAL=75
		# shellcheck source=../contributor-activity-helper-person.sh
		source "$PERSON_LIB"
		person_stats() {
			local repo_path="${1:-}"
			[[ -n "$repo_path" ]] || return 1
			return 1
		}
		_cross_repo_person_stats_collect_json month "" "$repo_dir" 2>"$stderr_file"
	)
	if [[ "$output" == "[]" ]] && grep -q '^PARTIAL=true$' "$stderr_file" && grep -q '^REPO_COUNT=1$' "$stderr_file"; then
		pass "$name"
	else
		fail "$name" "failed repository collection was treated as complete data"
	fi
	return 0
}

test_legacy_all_zero_cache_is_unavailable() {
	local name="dashboard rejects ambiguous legacy all-zero cache"
	local cache_dir="${TMP_DIR}/cache-legacy"
	local output
	mkdir -p "$cache_dir"
	cat >"${cache_dir}/person-stats-cache-cross-repo.md" <<'CACHE'
_Across 3 managed repos:_

| Contributor | Issues | PRs | Merged | Commented | % of Total |
| --- | ---: | ---: | ---: | ---: | ---: |
| alice | 0 | 0 | 0 | 0 | 0.0% |
CACHE
	output=$(
		PERSON_STATS_CACHE_DIR="$cache_dir"
		define_timeout_sec_mock
		# shellcheck source=../stats-health-dashboard-data.sh
		source "$DASHBOARD_LIB"
		_read_person_stats_cache "cross-repo"
	)
	if [[ "$output" == *"cached all-zero data predates collection-status diagnostics"* ]]; then
		pass "$name"
	else
		fail "$name" "ambiguous cached zero table was presented as verified activity data"
	fi
	return 0
}

test_person_stats_uses_portable_timeout() {
	local name="person stats wraps gh api with timeout_sec"
	local wrapper_pattern="timeout_sec \"\$timeout_budget\" gh api \"\$@\""
	if grep -Fq "$wrapper_pattern" "$PERSON_LIB" && grep -q 'PERSON_STATS_CROSS_REPO_GH_API_TIMEOUT' "$PERSON_LIB"; then
		pass "$name"
	else
		fail "$name" "missing portable gh api wrapper or cross-repo budget"
	fi
	return 0
}

test_person_stats_has_no_direct_timeout() {
	local name="person stats does not call direct timeout"
	if grep -Eq '(^|[[:space:]])timeout[[:space:]]+[0-9]' "$PERSON_LIB"; then
		fail "$name" "found direct timeout invocation"
	else
		pass "$name"
	fi
	return 0
}

test_dashboard_wraps_person_stats_with_timeout() {
	local name="dashboard wraps person-stats helpers with timeout_sec"
	local person_pattern="timeout_sec \"\$STATS_HEALTH_PERSON_STATS_TIMEOUT\" bash \"\$activity_helper\" person-stats"
	local cross_pattern="timeout_sec \"\$STATS_HEALTH_PERSON_STATS_TIMEOUT\" bash \"\$activity_helper\" cross-repo-person-stats"
	if grep -Fq "$person_pattern" "$DASHBOARD_LIB" && grep -Fq "$cross_pattern" "$DASHBOARD_LIB"; then
		pass "$name"
	else
		fail "$name" "missing dashboard wall-clock timeout around person-stats helper calls"
	fi
	return 0
}

test_dashboard_wraps_person_stats_rate_limit_probes() {
	local name="dashboard wraps person-stats rate-limit probes with timeout_sec"
	local helper_pattern="timeout_sec \"\$STATS_HEALTH_PERSON_STATS_RATE_LIMIT_TIMEOUT\" gh api rate_limit"
	local caller_pattern="search_remaining=\$(_stats_health_person_stats_search_remaining)"
	if grep -Fq "$helper_pattern" "$DASHBOARD_LIB" && grep -Fq "$caller_pattern" "$DASHBOARD_LIB"; then
		pass "$name"
	else
		fail "$name" "person-stats Search API budget probes can still call gh api without a wall-clock guard"
	fi
	return 0
}

test_dashboard_wraps_local_activity_helpers_with_timeout() {
	local name="dashboard bounds local activity helper calls"
	local summary_pattern="timeout_sec \"\$STATS_HEALTH_ACTIVITY_TIMEOUT\" bash \"\$activity_helper\" summary"
	local session_pattern="timeout_sec \"\$STATS_HEALTH_ACTIVITY_TIMEOUT\" bash \"\$activity_helper\" session-time"
	if grep -Fq "$summary_pattern" "$DASHBOARD_LIB" && grep -Fq "$session_pattern" "$DASHBOARD_LIB"; then
		pass "$name"
	else
		fail "$name" "missing wall-clock timeout around local activity or session-time helper"
	fi
	return 0
}

test_dashboard_preserves_partial_cache() {
	local name="dashboard caches partial person-stats output and updates marker"
	local fake_home="${TMP_DIR}/home-partial"
	mkdir -p "${fake_home}/.aidevops/agents/scripts" "${TMP_DIR}/cache" "${TMP_DIR}/bin"
	cat >"${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh" <<'FAKE'
#!/usr/bin/env bash
case "$1" in
person-stats)
	printf '%s\n' '| Contributor | Issues | PRs | Merged | Commented | % of Total |'
	exit 75
	;;
cross-repo-person-stats)
	printf '%s\n' '_Across 2 managed repos:_'
	exit 75
	;;
esac
exit 1
FAKE
	chmod +x "${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	cat >"${TMP_DIR}/repos.json" <<JSON
{"initialized_repos":[{"pulse":true,"local_only":false,"slug":"owner/repo1","path":"${TMP_DIR}/repo1"},{"pulse":true,"local_only":false,"slug":"owner/repo2","path":"${TMP_DIR}/repo2"}]}
JSON
	mkdir -p "${TMP_DIR}/repo1" "${TMP_DIR}/repo2"
	cat >"${TMP_DIR}/bin/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
	printf '%s\n' '1000'
	exit 0
fi
exit 1
GH
	chmod +x "${TMP_DIR}/bin/gh"
	(
		HOME="$fake_home"
		LOGFILE="${TMP_DIR}/partial.log"
		REPOS_JSON="${TMP_DIR}/repos.json"
		PERSON_STATS_INTERVAL=0
		PERSON_STATS_LAST_RUN="${TMP_DIR}/partial.last"
		PERSON_STATS_CACHE_DIR="${TMP_DIR}/cache"
		define_timeout_sec_mock
		PATH="${TMP_DIR}/bin:${PATH}"
		export HOME LOGFILE REPOS_JSON PERSON_STATS_INTERVAL PERSON_STATS_LAST_RUN PERSON_STATS_CACHE_DIR PATH
		# shellcheck source=../stats-health-dashboard-data.sh
		source "$DASHBOARD_LIB"
		_refresh_person_stats_cache
	)
	if [[ -s "${TMP_DIR}/partial.last" && -s "${TMP_DIR}/cache/person-stats-cache-owner-repo1.md" && -s "${TMP_DIR}/cache/person-stats-cache-cross-repo.md" ]]; then
		pass "$name"
	else
		fail "$name" "partial outputs were not cached or last-run marker missing"
	fi
	return 0
}

test_dashboard_skips_marker_when_all_refreshes_fail() {
	local name="dashboard does not mark success when all person-stats calls fail"
	local fake_home="${TMP_DIR}/home-fail"
	mkdir -p "${fake_home}/.aidevops/agents/scripts" "${TMP_DIR}/cache-fail" "${TMP_DIR}/bin-fail"
	cat >"${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh" <<'FAKE'
#!/usr/bin/env bash
exit 124
FAKE
	chmod +x "${fake_home}/.aidevops/agents/scripts/contributor-activity-helper.sh"
	cat >"${TMP_DIR}/repos-fail.json" <<JSON
{"initialized_repos":[{"pulse":true,"local_only":false,"slug":"owner/repo1","path":"${TMP_DIR}/repo1"},{"pulse":true,"local_only":false,"slug":"owner/repo2","path":"${TMP_DIR}/repo2"}]}
JSON
	cat >"${TMP_DIR}/bin-fail/gh" <<'GH'
#!/usr/bin/env bash
if [[ "$1" == "api" && "$2" == "rate_limit" ]]; then
	printf '%s\n' '1000'
	exit 0
fi
exit 1
GH
	chmod +x "${TMP_DIR}/bin-fail/gh"
	(
		HOME="$fake_home"
		LOGFILE="${TMP_DIR}/fail.log"
		REPOS_JSON="${TMP_DIR}/repos-fail.json"
		PERSON_STATS_INTERVAL=0
		PERSON_STATS_LAST_RUN="${TMP_DIR}/fail.last"
		PERSON_STATS_CACHE_DIR="${TMP_DIR}/cache-fail"
		define_timeout_sec_mock
		PATH="${TMP_DIR}/bin-fail:${PATH}"
		export HOME LOGFILE REPOS_JSON PERSON_STATS_INTERVAL PERSON_STATS_LAST_RUN PERSON_STATS_CACHE_DIR PATH
		# shellcheck source=../stats-health-dashboard-data.sh
		source "$DASHBOARD_LIB"
		_refresh_person_stats_cache
	)
	if [[ ! -e "${TMP_DIR}/fail.last" ]] && grep -q 'last-run marker not updated' "${TMP_DIR}/fail.log"; then
		pass "$name"
	else
		fail "$name" "failure refresh wrote a success marker or omitted log evidence"
	fi
	return 0
}

test_person_stats_uses_portable_timeout
test_person_stats_has_no_direct_timeout
test_failed_queries_are_partial
test_cross_repo_all_zero_semantics
test_cross_repo_collection_failures_are_partial
test_legacy_all_zero_cache_is_unavailable
test_dashboard_wraps_person_stats_with_timeout
test_dashboard_wraps_person_stats_rate_limit_probes
test_dashboard_wraps_local_activity_helpers_with_timeout
test_dashboard_preserves_partial_cache
test_dashboard_skips_marker_when_all_refreshes_fail

if [[ "$FAIL" -ne 0 ]]; then
	printf 'FAIL contributor-activity-helper-person (%s failed, %s passed)\n' "$FAIL" "$PASS"
	exit 1
fi

printf 'PASS contributor-activity-helper-person (%s checks)\n' "$PASS"
