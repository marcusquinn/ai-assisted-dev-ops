#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1

TESTS_RUN=0
TESTS_FAILED=0

pass() { TESTS_RUN=$((TESTS_RUN + 1)); printf '  PASS %s\n' "$1"; return 0; }
fail() { TESTS_RUN=$((TESTS_RUN + 1)); TESTS_FAILED=$((TESTS_FAILED + 1)); printf '  FAIL %s\n       %s\n' "$1" "${2:-}"; return 0; }

TMP=$(mktemp -d -t health-identity.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

export HOME="${TMP}/home"
export LOGFILE="${TMP}/stats.log"
export AIDEVOPS_IDENTITY_ALIASES_CONF="${TMP}/identity-aliases.conf"
mkdir -p "${HOME}/.aidevops/logs"
: >"$LOGFILE"

printf '%s\n' 'canonical-operator=local-user,github-user' >"$AIDEVOPS_IDENTITY_ALIASES_CONF"

GH_CALLS="${TMP}/gh-calls.log"
: >"$GH_CALLS"

# shellcheck disable=SC2317
gh() {
	local call="$*"
	printf '%s\n' "$call" >>"$GH_CALLS"
	case "${HEALTH_FIXTURE:-}:$call" in
		empty_login:*"api user --jq .login"*)
			printf '%s' ''
			return 0
			;;
		rate_limit_login:*"api user --jq .login"*)
			printf '%s' '{"message":"API rate limit exceeded", "status":"403"}' >&2
			return 1
			;;
		conflicting_operator:*"issue list --repo owner/repo --label persistent"*)
			printf '%s' '[{"number":4643,"title":"[Supervisor:marcusquinn] stale dashboard","labels":[{"name":"source:health-dashboard"},{"name":"operator:alex-solovyev"},{"name":"alex-solovyev"},{"name":"supervisor"}]}]'
			return 0
			;;
		conflicting_operator:*"issue list --repo owner/repo --search in:title [Supervisor:marcusquinn]"*)
			printf '%s' '[{"number":4643,"title":"[Supervisor:marcusquinn] stale dashboard","labels":[{"name":"source:health-dashboard"},{"name":"operator:alex-solovyev"},{"name":"alex-solovyev"},{"name":"supervisor"}]}]'
			return 0
			;;
		legacy_title:*"issue list --repo owner/repo --label persistent"*)
			printf '%s' '[{"number":555,"title":"[Supervisor:github-user] legacy dashboard","labels":[{"name":"source:health-dashboard"},{"name":"supervisor"},{"name":"github-user"}]}]'
			return 0
			;;
		cache_conflict:*"issue view 4643 --repo owner/repo --json state,labels"*)
			printf '%s' '{"state":"OPEN","labels":[{"name":"source:health-dashboard"},{"name":"operator:alex-solovyev"}]}'
			return 0
			;;
		cache_open_state:*"issue view 4644 --repo owner/repo --json state,labels"*)
			printf '%s' 'OPEN'
			return 0
			;;
		cache_closed_state:*"issue view 4645 --repo owner/repo --json state,labels"*)
			printf '%s' 'CLOSED'
			return 0
			;;
		activity_guard_autodispatch:*"issue list --repo owner/repo --assignee github-user"*)
			printf '%s' '0'
			return 0
			;;
		activity_guard_autodispatch:*"issue list --repo owner/repo --label auto-dispatch"*)
			printf '%s' '1'
			return 0
			;;
		activity_guard_idle:*"issue list --repo owner/repo --assignee github-user"*)
			printf '%s' '0'
			return 0
			;;
		activity_guard_idle:*"issue list --repo owner/repo --label auto-dispatch"*)
			printf '%s' '0'
			return 0
			;;
		:*"issue list --repo owner/repo --label persistent"*)
			printf '%s' '[{"number":20408,"title":"[Supervisor:github-user] 1 PR at 10:00 UTC","labels":[{"name":"source:health-dashboard"},{"name":"supervisor"},{"name":"github-user"}],"createdAt":"2026-05-01T10:00:00Z"},{"number":18669,"title":"[Contributor:local-user] 0 PRs at 09:00 UTC","labels":[{"name":"source:health-dashboard"},{"name":"contributor"},{"name":"local-user"}],"createdAt":"2026-04-01T09:00:00Z"}]'
			return 0
			;;
		*) return 0 ;;
	esac
	return 0
}

# shellcheck disable=SC2317
whoami() {
	if [[ -n "${HEALTH_WHOAMI_FIXTURE:-}" ]]; then
		printf '%s' "$HEALTH_WHOAMI_FIXTURE"
		return 0
	fi
	command whoami "$@"
	return $?
}

# shellcheck disable=SC2317
gh_issue_list() { gh issue list "$@" && return 0; return 1; }
# shellcheck disable=SC2317
gh_issue_view() { gh issue view "$@" && return 0; return 1; }
# shellcheck disable=SC2317
gh_create_issue() { gh issue create "$@" && return 0; return 1; }
# shellcheck disable=SC2317
gh_issue_edit_safe() { gh issue edit "$@" && return 0; return 1; }
# shellcheck disable=SC2317
gh_pr_list() {
	printf 'pr list %s\n' "$*" >>"$GH_CALLS"
	printf '%s' "${HEALTH_PR_COUNT:-0}"
	return 0
}

# shellcheck source=../portable-stat.sh
source "${SCRIPTS_DIR}/portable-stat.sh"
# shellcheck source=../stats-shared.sh
source "${SCRIPTS_DIR}/stats-shared.sh"
# shellcheck source=../stats-health-dashboard.sh
source "${SCRIPTS_DIR}/stats-health-dashboard.sh"

# shellcheck disable=SC2317
_unpin_health_issue() { printf 'unpin %s\n' "$*" >>"$GH_CALLS"; return 0; }

# shellcheck disable=SC2317
_scan_active_workers() {
	if [[ "${HEALTH_ACTIVE_WORKERS:-0}" -gt 0 ]]; then
		printf '%s\0%s\0%s\0' '_Active workers_' "$HEALTH_ACTIVE_WORKERS" ''
		return 0
	fi
	printf '%s\0%s\0%s\0' '_No active workers_' '0' ''
	return 0
}

identity_lines=$(_dashboard_identity_aliases "github-user")
canonical=$(printf '%s\n' "$identity_lines" | sed -n '1p')
aliases=$(printf '%s\n' "$identity_lines" | sed '1d')

if [[ "$canonical" == "canonical-operator" ]]; then
	pass "resolves GitHub username to canonical operator"
else
	fail "resolves GitHub username to canonical operator" "canonical=${canonical}"
fi

preloaded_identity_lines=$(_dashboard_identity_aliases "github-user" \
	'preloaded-operator=github-user')
preloaded_canonical=$(printf '%s\n' "$preloaded_identity_lines" | sed -n '1p')
if [[ "$preloaded_canonical" == "preloaded-operator" ]]; then
	pass "resolves aliases from preloaded config content without rereading disk config"
else
	fail "resolves aliases from preloaded config content without rereading disk config" "canonical=${preloaded_canonical}"
fi

result=$(_find_health_issue "owner/repo" "github-user" "supervisor" "[Supervisor:canonical-operator]" \
	"supervisor" "Supervisor" "${HOME}/.aidevops/logs/health-issue-canonical-owner-repo" \
	"$canonical" "$aliases")

if [[ "$result" == "20408" ]]; then
	pass "keeps deterministic newest dashboard across aliases and roles"
else
	fail "keeps deterministic newest dashboard across aliases and roles" "result=${result}"
fi

if grep -q 'issue close 18669' "$GH_CALLS"; then
	pass "closes stale alias dashboard"
else
	fail "closes stale alias dashboard" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

if grep -q 'canonical operator canonical-operator' "$GH_CALLS"; then
	pass "dedup close comment names canonical identity"
else
	fail "dedup close comment names canonical identity" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

before_malformed_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)
_close_health_issue_identity_duplicates \
	'[{"number":20408},{"number":20316},{"number":18669}]' \
	$'https://example.invalid/issues/20316\nhttps://example.invalid/issues/18669\n20408' \
	"owner/repo" "canonical-operator" "github-user"
after_malformed_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)

if [[ "$after_malformed_close_count" == "$before_malformed_close_count" ]]; then
	pass "does not close persistent dashboards without one numeric supersession target"
else
	fail "does not close persistent dashboards without one numeric supersession target" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

before_periodic_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)
HEALTH_DEDUP_INTERVAL=0 _periodic_health_issue_dedup \
	"owner/repo" "github-user" "supervisor" "supervisor" "Supervisor" \
	$'https://example.invalid/issues/20316\nhttps://example.invalid/issues/18669\n20408' \
	"canonical-operator" "$aliases"
after_periodic_close_count=$(grep -c 'issue close' "$GH_CALLS" || true)

if [[ "$after_periodic_close_count" == "$before_periodic_close_count" ]]; then
	pass "periodic dedup skips malformed cached current issue"
else
	fail "periodic dedup skips malformed cached current issue" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

extracted=$(_health_issue_number_from_text $'noise\nhttps://example.invalid/issues/20316\n20408')
if [[ "$extracted" == "20408" ]]; then
	pass "extracts one issue number from noisy wrapper output"
else
	fail "extracts one issue number from noisy wrapper output" "extracted=${extracted}"
fi

: >"$GH_CALLS"
export HEALTH_FIXTURE=conflicting_operator
result=$(_find_health_issue \
	"owner/repo" "marcusquinn" "supervisor" "[Supervisor:marcusquinn]" \
	"supervisor" "Supervisor" "${HOME}/.aidevops/logs/health-issue-marcusquinn-owner-repo" \
	"marcusquinn" "marcusquinn")
unset HEALTH_FIXTURE

if [[ -z "$result" ]]; then
	pass "does not reuse dashboard with conflicting operator label despite matching title"
else
	fail "does not reuse dashboard with conflicting operator label despite matching title" "result=${result}; calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

: >"$GH_CALLS"
export HEALTH_FIXTURE=legacy_title
result=$(_find_health_issue \
	"owner/repo" "github-user" "supervisor" "[Supervisor:canonical-operator]" \
	"supervisor" "Supervisor" "${HOME}/.aidevops/logs/health-issue-legacy-owner-repo" \
	"canonical-operator" "$aliases")
unset HEALTH_FIXTURE

if [[ "$result" == "555" ]]; then
	pass "keeps legacy title migration when no operator label exists"
else
	fail "keeps legacy title migration when no operator label exists" "result=${result}; calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

cache_file="${HOME}/.aidevops/logs/health-issue-cache-conflict-owner-repo"
printf '%s\n' '4643' >"$cache_file"
: >"$GH_CALLS"
export HEALTH_FIXTURE=cache_conflict
result=$(_find_health_issue \
	"owner/repo" "marcusquinn" "supervisor" "[Supervisor:marcusquinn]" \
	"supervisor" "Supervisor" "$cache_file" \
	"marcusquinn" "marcusquinn")
unset HEALTH_FIXTURE

if [[ -z "$result" && ! -f "$cache_file" ]]; then
	pass "drops cached dashboard with conflicting operator label"
else
	fail "drops cached dashboard with conflicting operator label" "result=${result}; cache_exists=$([[ -f "$cache_file" ]] && printf yes || printf no); calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

if _health_issue_operator_label_allows_identity "" "canonical-operator"; then
	pass "allows empty cached issue metadata as unknown rather than jq parse failure"
else
	fail "allows empty cached issue metadata as unknown rather than jq parse failure" "empty input was rejected"
fi

if _health_issue_operator_label_allows_identity "OPEN" "canonical-operator"; then
	pass "allows raw open state metadata as unknown rather than jq parse failure"
else
	fail "allows raw open state metadata as unknown rather than jq parse failure" "OPEN input was rejected"
fi

cache_file="${HOME}/.aidevops/logs/health-issue-cache-open-owner-repo"
printf '%s\n' '4644' >"$cache_file"
: >"$GH_CALLS"
export HEALTH_FIXTURE=cache_open_state
result=$(_find_health_issue \
	"owner/repo" "marcusquinn" "supervisor" "[Supervisor:marcusquinn]" \
	"supervisor" "Supervisor" "$cache_file" \
	"marcusquinn" "marcusquinn")
unset HEALTH_FIXTURE

if [[ "$result" == "4644" && -f "$cache_file" ]]; then
	pass "keeps raw OPEN cached dashboard state without jq parse noise"
else
	fail "keeps raw OPEN cached dashboard state without jq parse noise" "result=${result}; cache_exists=$([[ -f "$cache_file" ]] && printf yes || printf no); calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

cache_file="${HOME}/.aidevops/logs/health-issue-cache-closed-owner-repo"
printf '%s\n' '4645' >"$cache_file"
: >"$GH_CALLS"
export HEALTH_FIXTURE=cache_closed_state
result=$(_find_health_issue \
	"owner/repo" "marcusquinn" "supervisor" "[Supervisor:marcusquinn]" \
	"supervisor" "Supervisor" "$cache_file" \
	"marcusquinn" "marcusquinn")
unset HEALTH_FIXTURE

if [[ -z "$result" && ! -f "$cache_file" ]]; then
	pass "drops raw CLOSED cached dashboard state without jq parse noise"
else
	fail "drops raw CLOSED cached dashboard state without jq parse noise" "result=${result}; cache_exists=$([[ -f "$cache_file" ]] && printf yes || printf no); calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

body=$(_build_health_issue_body \
	"2026-05-08T00:00:00Z" "Supervisor" "github-user" "owner/repo" \
	"0" "0" "0" "0" "4" "1" "0" "" \
	"_No open PRs_" "_No active workers_" "_Person stats_" "_Cross stats_" \
	"_Session time_" "_Cross session_" "_Activity_" "_Cross activity_" \
	"0" "4" "0.00" "0.00" "low" "100" "supervisor" \
	"—" "—" "0" "0" "_No diagnostics_" "$canonical" "$aliases")

if [[ "$body" == *"canonical:"* && "$body" == *"canonical-operator"* && "$body" == *"local-user"* ]]; then
	pass "dashboard body exposes canonical identity context"
else
	fail "dashboard body exposes canonical identity context" "$body"
fi

: >"$LOGFILE"
export HEALTH_FIXTURE=rate_limit_login
resolved_login=$(_resolve_current_gh_login_or_fallback)
unset HEALTH_FIXTURE

if [[ "$resolved_login" != *"message"* && "$resolved_login" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]]; then
	pass "falls back to validated local identity when gh login is rate limited"
else
	fail "falls back to validated local identity when gh login is rate limited" "resolved=${resolved_login}"
fi

export HEALTH_FIXTURE=empty_login
export HEALTH_WHOAMI_FIXTURE="local.user-name"
resolved_login=$(_resolve_current_gh_login_or_fallback)
unset HEALTH_FIXTURE HEALTH_WHOAMI_FIXTURE

if [[ "$resolved_login" == "local.user-name" ]]; then
	pass "allows dotted underscored and hyphenated local fallback identities"
else
	fail "allows dotted underscored and hyphenated local fallback identities" "resolved=${resolved_login}"
fi

export HEALTH_FIXTURE=empty_login
export HEALTH_WHOAMI_FIXTURE="local/user"
resolved_login=$(_resolve_current_gh_login_or_fallback)
unset HEALTH_FIXTURE HEALTH_WHOAMI_FIXTURE

if [[ "$resolved_login" == "unknown-runner" ]]; then
	pass "rejects unsafe local fallback identities before label and cache use"
else
	fail "rejects unsafe local fallback identities before label and cache use" "resolved=${resolved_login}"
fi

unsafe_cache=$(_sanitize_runner_identity_for_cache '{"message":"API rate limit exceeded", "status":"403"}local-user')
if [[ "$unsafe_cache" != *"{"* && "$unsafe_cache" != *"message\":"* && ${#unsafe_cache} -le 80 ]]; then
	pass "sanitizes API error payloads before cache filename use"
else
	fail "sanitizes API error payloads before cache filename use" "safe=${unsafe_cache}"
fi

missing_cache_file="${HOME}/.aidevops/logs/health-issue-missing-owner-repo"
rm -f "$missing_cache_file"
: >"$GH_CALLS"
: >"$LOGFILE"
export HEALTH_ACTIVE_WORKERS=2
if _check_health_issue_activity_guard "owner/repo" "$TMP" "github-user" "$missing_cache_file" && [[ ! -s "$GH_CALLS" ]]; then
	pass "activity guard short-circuits on active workers before network calls"
else
	fail "activity guard short-circuits on active workers before network calls" "calls=$(tr '\n' ';' <"$GH_CALLS"); log=$(tr '\n' ';' <"$LOGFILE")"
fi
unset HEALTH_ACTIVE_WORKERS

rm -f "$missing_cache_file"
: >"$GH_CALLS"
: >"$LOGFILE"
export HEALTH_PR_COUNT=1
if _check_health_issue_activity_guard "owner/repo" "$TMP" "github-user" "$missing_cache_file" && ! grep -q 'issue list' "$GH_CALLS"; then
	pass "activity guard short-circuits on open PRs before issue lookups"
else
	fail "activity guard short-circuits on open PRs before issue lookups" "calls=$(tr '\n' ';' <"$GH_CALLS"); log=$(tr '\n' ';' <"$LOGFILE")"
fi
unset HEALTH_PR_COUNT

rm -f "$missing_cache_file"
: >"$GH_CALLS"
: >"$LOGFILE"
export HEALTH_FIXTURE=activity_guard_autodispatch
if _check_health_issue_activity_guard "owner/repo" "$TMP" "github-user" "$missing_cache_file"; then
	pass "activity guard proceeds when auto-dispatch work is queued"
else
	fail "activity guard proceeds when auto-dispatch work is queued" "calls=$(tr '\n' ';' <"$GH_CALLS"); log=$(tr '\n' ';' <"$LOGFILE")"
fi
unset HEALTH_FIXTURE

rm -f "$missing_cache_file"
: >"$GH_CALLS"
: >"$LOGFILE"
export HEALTH_FIXTURE=activity_guard_idle
if _check_health_issue_activity_guard "owner/repo" "$TMP" "github-user" "$missing_cache_file"; then
	fail "activity guard skips when PRs issues workers and auto-dispatch are absent" "calls=$(tr '\n' ';' <"$GH_CALLS"); log=$(tr '\n' ';' <"$LOGFILE")"
else
	if grep -q 'auto-dispatch work' "$LOGFILE"; then
		pass "activity guard skips when PRs issues workers and auto-dispatch are absent"
	else
		fail "activity guard skip log names auto-dispatch work" "log=$(tr '\n' ';' <"$LOGFILE")"
	fi
fi
unset HEALTH_FIXTURE

cache_file="${HOME}/.aidevops/logs/health-issue-idle-owner-repo"
printf '%s\n' '20408' >"$cache_file"
: >"$GH_CALLS"
: >"$LOGFILE"
export HEALTH_FIXTURE=activity_guard_idle
if _check_health_issue_activity_guard "owner/repo" "$TMP" "github-user" "$cache_file" \
	&& [[ "$_HEALTH_ISSUE_ACTIVITY_STATE" == "idle" ]]; then
	pass "cached dashboard publishes first observed idle transition"
else
	fail "cached dashboard publishes first observed idle transition" "state=${_HEALTH_ISSUE_ACTIVITY_STATE:-}; log=$(tr '\n' ';' <"$LOGFILE")"
fi

_record_health_issue_refresh_state "$cache_file" "idle"
: >"$LOGFILE"
if _check_health_issue_activity_guard "owner/repo" "$TMP" "github-user" "$cache_file"; then
	fail "cached idle dashboard defers full refresh inside idle interval" "log=$(tr '\n' ';' <"$LOGFILE")"
else
	if grep -q 'deferring unchanged idle dashboard' "$LOGFILE"; then
		pass "cached idle dashboard defers full refresh inside idle interval"
	else
		fail "cached idle dashboard deferral is observable" "log=$(tr '\n' ';' <"$LOGFILE")"
	fi
fi

_record_health_issue_refresh_state "$cache_file" "active"
if _check_health_issue_activity_guard "owner/repo" "$TMP" "github-user" "$cache_file"; then
	pass "cached dashboard publishes active-to-idle transition immediately"
else
	fail "cached dashboard publishes active-to-idle transition immediately" "log=$(tr '\n' ';' <"$LOGFILE")"
fi
unset HEALTH_FIXTURE

: >"$GH_CALLS"
priority_entries=$(_prioritize_health_repo_entries $'owner/slow|/repo/slow\nmarcusquinn/aidevops|/repo/framework\nowner/other|/repo/other')
if [[ "$priority_entries" == $'marcusquinn/aidevops|/repo/framework\nowner/slow|/repo/slow\nowner/other|/repo/other' ]]; then
	pass "health dashboard prioritizes the framework repository without dropping entries"
else
	fail "health dashboard prioritizes the framework repository without dropping entries" "entries=${priority_entries}"
fi

STATS_HEALTH_PRIORITY_REPO="owner/other"
priority_entries=$(_prioritize_health_repo_entries $'owner/slow|/repo/slow\nmarcusquinn/aidevops|/repo/framework\nowner/other|/repo/other')
unset STATS_HEALTH_PRIORITY_REPO
if [[ "$priority_entries" == $'owner/other|/repo/other\nowner/slow|/repo/slow\nmarcusquinn/aidevops|/repo/framework' ]]; then
	pass "health dashboard supports an explicit priority repository override"
else
	fail "health dashboard supports an explicit priority repository override" "entries=${priority_entries}"
fi

: >"$GH_CALLS"
export HEALTH_FIXTURE=label_hygiene
gh() {
	local call="$*"
	printf '%s\n' "$call" >>"$GH_CALLS"
	if [[ "$call" == *"issue view 20408 --repo owner/repo --json labels"* ]]; then
		printf '%s' '{"labels":[{"name":"persistent"},{"name":"source:health-dashboard"},{"name":"supervisor"},{"name":"github-user"},{"name":"operator:canonical-operator"},{"name":"origin:worker"},{"name":"origin:interactive"},{"name":"origin:worker-takeover"},{"name":"auto-dispatch"},{"name":"status:available"}]}'
	fi
	return 0
}
_normalize_health_issue_labels "20408" "owner/repo" "github-user" "supervisor" "canonical-operator"
if grep -q -- '--remove-label auto-dispatch' "$GH_CALLS" \
	&& grep -q -- '--remove-label status:available' "$GH_CALLS" \
	&& grep -q -- '--remove-label origin:interactive' "$GH_CALLS" \
	&& grep -q -- '--remove-label origin:worker-takeover' "$GH_CALLS"; then
	pass "dashboard label normalization removes task lifecycle labels"
else
	fail "dashboard label normalization removes task lifecycle labels" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

: >"$GH_CALLS"
gh() {
	local call="$*"
	printf '%s\n' "$call" >>"$GH_CALLS"
	if [[ "$call" == *"issue view 20408 --repo owner/repo --json title"* ]]; then
		printf '%s' '[Supervisor:github-user] 1 PR, 0 assigned, 0 workers at 10:00 UTC'
	fi
	return 0
}
_update_health_issue_title \
	"20408" "owner/repo" "[Supervisor:github-user]" "1" "0" "0" \
	"2026-08-09T05:30:00Z"
if grep -q -- '--title \[Supervisor:github-user\] 1 open PR, 0 issues assigned, 0 local workers — changed 2026-08-09 05:30 UTC' "$GH_CALLS"; then
	pass "dashboard title explains metric scope and dates the changed snapshot"
else
	fail "dashboard title explains metric scope and dates the changed snapshot" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

: >"$GH_CALLS"
gh() {
	local call="$*"
	printf '%s\n' "$call" >>"$GH_CALLS"
	if [[ "$call" == *"issue view 20408 --repo owner/repo --json title"* ]]; then
		printf '%s' '[Supervisor:github-user] 1 open PR, 0 issues assigned, 0 local workers — changed 2026-08-09 05:30 UTC'
	fi
	return 0
}
_update_health_issue_title \
	"20408" "owner/repo" "[Supervisor:github-user]" "1" "0" "0" \
	"2026-08-09T06:30:00Z"
if ! grep -q 'issue edit' "$GH_CALLS"; then
	pass "unchanged dashboard metrics preserve the existing changed timestamp"
else
	fail "unchanged dashboard metrics preserve the existing changed timestamp" "calls=$(tr '\n' ';' <"$GH_CALLS")"
fi

printf '\n== Summary ==\n'
if ((TESTS_FAILED > 0)); then
	printf '  %d failed of %d tests\n' "$TESTS_FAILED" "$TESTS_RUN"
	exit 1
fi
printf '  All %d tests passed\n' "$TESTS_RUN"
exit 0
