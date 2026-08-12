#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dashboard-freshness-check.sh — t2418 regression guard (GH#20016).
#
# Exercises the supervisor-dashboard staleness watchdog across its five
# core behaviours:
#
#   1. check-body on a fresh body → exit 0, prints a non-zero-age line.
#   2. check-body on a stale body → exit 1, prints an age line.
#   3. check-body on a body missing the last_refresh marker → exit 1,
#      prints "MISSING".
#   4. scan with a stale dashboard fixture → files exactly one operator-owned,
#      non-dispatchable alert issue via the stubbed `gh` invocation.
#   5. scan with a stale dashboard AND a pre-existing open alert → files
#      NO second alert (dedup via <!-- aidevops:dashboard-freshness:*:* -->
#      generated-title match scoped to the dashboard issue suffix).
#   6. source regression: dedup lookup keeps jq variables in --arg bindings
#      and leaves jq stderr visible so syntax failures are not hidden.
#   7. scan with a fresh dashboard → files no alert.
#   8. cadence gate: a second scan within the interval is short-circuited
#      without calling `gh`.
#   9. scan with a fresh dashboard AND a pre-existing generated alert → posts
#      recovery evidence and closes the alert.
#  10. scan with a stale dashboard AND a pre-existing missing-marker alert →
#      closes the recovered missing-marker alert and files a stale alert.
#  11. open issue list failures are logged instead of silently treated as an
#      empty dedup result.
#  12. scan without a local health-issue cache falls back to the authenticated
#      operator's open source:health-dashboard issue for configured repos, and
#      remote reconciliation remains active when a local cache exists.
#  13. local cache candidates must match the authenticated operator.
#  14. a closed incident with the same last_refresh is reopened, not duplicated.
#  15. source regression: recovered stale and missing-marker alert paths share
#      the parameterized close helper and accept a pre-fetched open issue list.
#
# The scanner is expected to use `command -v gh` + `gh auth status` guards
# and to fail-open on every error path; the test sets up a self-contained
# HOME so nothing leaks into the user's real state.
#
# Stub strategy: export a minimal `gh` shell function in a per-test
# environment, then invoke the scanner as a subprocess with
# `bash -c 'source stubs; exec scanner …'` so the function is inherited.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR_TEST}/.." && pwd)" || exit 1
SCANNER="${SCRIPTS_DIR}/dashboard-freshness-check.sh"

if [[ ! -x "$SCANNER" ]]; then
	echo "FATAL: scanner not executable: $SCANNER" >&2
	exit 2
fi

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN=""
	TEST_RED=""
	TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$1"
	if [[ -n "${2:-}" ]]; then
		printf '       %s\n' "$2"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Sandbox
# ---------------------------------------------------------------------------
TMP="$(mktemp -d -t t2418.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT

# A per-test isolated HOME so cache/log/state writes don't touch real state.
HOME_ISO="${TMP}/home"
mkdir -p "${HOME_ISO}/.aidevops/logs" \
	"${HOME_ISO}/.aidevops/cache/dashboard-freshness" \
	"${HOME_ISO}/.config/aidevops" \
	"${HOME_ISO}/.aidevops/agents/scripts"

# repos.json: one entry with slug = test/repo so _resolve_slug_from_dashed
# can map "test-repo" → "test/repo".
cat >"${HOME_ISO}/.config/aidevops/repos.json" <<'EOF'
{
	"initialized_repos": [
		{ "slug": "test/repo", "pulse": true }
	],
	"git_parent_dirs": []
}
EOF

# Health-issue cache pointing at dashboard issue 424242 on slug test/repo.
# Filename format mirrors current canonical caches:
# health-issue-<canonical-operator>-<slug-dashed>.
HEALTH_CACHE="${HOME_ISO}/.aidevops/logs/health-issue-testrunner-test-repo"
printf '%s\n' 424242 >"$HEALTH_CACHE"

# ---------------------------------------------------------------------------
# Body fixtures
# ---------------------------------------------------------------------------
NOW_ISO="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STALE_ISO="2026-04-01T00:00:00Z" # ~3 weeks old — well past 48h threshold

FRESH_BODY="${TMP}/fresh-body.md"
cat >"$FRESH_BODY" <<EOF
## Queue Health Dashboard

**Last pulse**: \`${NOW_ISO}\`

<!-- aidevops:dashboard-freshness -->
last_refresh: ${NOW_ISO}

### Summary
EOF

STALE_BODY="${TMP}/stale-body.md"
cat >"$STALE_BODY" <<EOF
## Queue Health Dashboard

**Last pulse**: \`${STALE_ISO}\`

<!-- aidevops:dashboard-freshness -->
last_refresh: ${STALE_ISO}

### Summary
EOF

MISSING_BODY="${TMP}/missing-body.md"
cat >"$MISSING_BODY" <<'EOF'
## Queue Health Dashboard

**Last pulse**: `2026-04-20T00:00:00Z`

### Summary
EOF

# ---------------------------------------------------------------------------
# Test 1-3: check-body mode exit codes and output
# ---------------------------------------------------------------------------
echo "Testing: check-body parsing"

out="$(bash "$SCANNER" check-body "$FRESH_BODY" 2>&1)"
ec=$?
if [[ "$ec" == 0 ]] && [[ "$out" == *"age_seconds="* ]] && [[ "$out" != *"MISSING"* ]]; then
	pass "check-body on fresh body → exit 0 + age line"
else
	fail "check-body on fresh body" "ec=$ec out='$out'"
fi

out="$(bash "$SCANNER" check-body "$STALE_BODY" 2>&1)"
ec=$?
if [[ "$ec" == 1 ]] && [[ "$out" == *"age_seconds="* ]]; then
	pass "check-body on stale body → exit 1 + age line"
else
	fail "check-body on stale body" "ec=$ec out='$out'"
fi

out="$(bash "$SCANNER" check-body "$MISSING_BODY" 2>&1)"
ec=$?
if [[ "$ec" == 1 ]] && [[ "$out" == "MISSING" ]]; then
	pass "check-body on missing-marker body → exit 1 + MISSING"
else
	fail "check-body on missing-marker body" "ec=$ec out='$out'"
fi

# ---------------------------------------------------------------------------
# Scan harness — runs the scanner with stubbed `gh` and isolated HOME.
# Arguments:
#   $1 — body fixture file
#   $2 — 0|1 should alert_already_open return "alert exists"
#   $3 — extra env (space-separated KEY=VAL)
# Writes a fresh GH_CALLS log to $TMP/gh-calls.log and runs the scanner.
# ---------------------------------------------------------------------------
run_scan_stub_script() {
	cat <<'EOF'
			set +u
			# Stub gh: records every call and returns canned responses
			# for the paths the scanner exercises:
			#   gh auth status       → success
			#   gh api repos/.../issues/N  → dashboard issue JSON (body from fixture)
			#   gh api --paginate repos/.../issues?state=open... → alert dedup/recovery check
			#   gh issue create ...  → URL + 0
			stub_gh_api() {
				local gh_args="$1"
				if [[ "$gh_args" == *"user --jq .login // \"\""* ]]; then
					printf '%s\n' "testrunner"
					return 0
				fi
				if [[ "$gh_args" == *"repos/test/repo/issues?state=open&labels=source%3Ahealth-dashboard,supervisor&per_page=100"* ]]; then
					[[ "${DASHBOARD_TITLE:-}" == "[Supervisor:historical] stale" ]] || printf '%s\n' 424242
					return 0
				fi
				if [[ "$gh_args" == *"search/issues"* ]] && [[ "$gh_args" == *"(#424242)"* ]]; then
					[[ "${INCIDENT_SEARCH_FAIL:-0}" == "1" ]] && return 1
					if [[ "${INCIDENT_EXISTS:-0}" == "1" ]]; then
						jq -n --arg state "${INCIDENT_STATE:-closed}" --arg body "Dashboard last refreshed \`${STALE_ISO}\` <!-- aidevops:dashboard-freshness:test/repo:424242 -->" \
							'{number: 98, state: $state, title: "Supervisor health dashboard stale: prior (#424242)", body: $body}'
					fi
					return 0
				fi
				if [[ "$gh_args" == *"repos/test/repo/issues?state=open&per_page=100"* ]]; then
					[[ "${GH_ISSUE_LIST_FAIL:-0}" == "1" ]] && return 1
					if [[ "$ALERT_EXISTS" == "1" ]]; then
						if [[ "$ALERT_KIND" == "missing" ]]; then
							printf '%s\n' '{"number":99,"title":"Supervisor health dashboard missing last_refresh marker (#424242)"}'
						else
							printf '%s\n' '{"number":99,"title":"Supervisor health dashboard stale: test/repo (#424242)"}'
						fi
					fi
					return 0
				fi
				if [[ "$gh_args" == *"repos/test/repo --jq .private | tostring"* ]]; then
					printf '%s\n' 'false'
					return 0
				fi
				jq -n --arg state "${DASHBOARD_STATE:-OPEN}" --arg title "${DASHBOARD_TITLE:-[Supervisor:testrunner] ok}" \
					--arg role "${DASHBOARD_ROLE_LABEL:-supervisor}" --arg operator "operator:${DASHBOARD_OPERATOR:-testrunner}" \
					--rawfile body "$BODY_FIXTURE" \
					'{state: $state, title: $title, labels: [{name: $role}, {name: $operator}], body: $body}'
				return 0
			}
			gh() {
				printf "%s\n" "$*" >> "$GH_CALLS_LOG"
				local gh_args="$*"
				case "$1" in
					auth)
						return 0
						;;
					api)
						stub_gh_api "$gh_args"
						return $?
						;;
					issue)
						case "$2" in
							comment | close | reopen | edit)
								return 0
								;;
							create)
								local prev=""
								local body_path=""
								for arg in "$@"; do
									if [[ "$prev" == "--body-file" ]]; then
										body_path="$arg"
										break
									fi
									prev="$arg"
								done
								if [[ -n "$body_path" && -f "$body_path" ]]; then
									cp "$body_path" "$ALERT_BODY_CAPTURE"
								fi
								printf "https://example.invalid/test/repo/issues/99\n"
								return 0
								;;
						esac
						return 0
						;;
				esac
				return 0
			}
			export -f gh stub_gh_api
			# shellcheck disable=SC1091
			eval "$EXTRA_ENV"
			# Force force-scan so the scanner does not throttle itself
			exec bash "$SCANNER_PATH" scan --force
EOF
	return 0
}

run_scan_with_stubs() {
	local body_file="$1"
	local alert_exists="$2"
	local extra_env="${3:-}"
	local alert_kind="${4:-stale}"
	local gh_calls="${TMP}/gh-calls.log"
	local alert_body_capture="${TMP}/alert-body.md"
	: >"$gh_calls"
	: >"$alert_body_capture"

	# Reset last-scan marker so cadence gate doesn't suppress unless the
	# test explicitly sets DASHBOARD_FRESHNESS_SCAN_INTERVAL high.
	rm -f "${HOME_ISO}/.aidevops/cache/dashboard-freshness/last-scan"

	# shellcheck disable=SC2016
	HOME="$HOME_ISO" \
		REPOS_JSON="${HOME_ISO}/.config/aidevops/repos.json" \
		DASHBOARD_FRESHNESS_SCAN_INTERVAL="${SCAN_INTERVAL:-1}" \
		DASHBOARD_FRESHNESS_THRESHOLD_SECONDS="172800" \
		GH_CALLS_LOG="$gh_calls" \
		BODY_FIXTURE="$body_file" \
		ALERT_EXISTS="$alert_exists" \
		ALERT_KIND="$alert_kind" \
		ALERT_BODY_CAPTURE="$alert_body_capture" \
		STALE_ISO="$STALE_ISO" \
		EXTRA_ENV="$extra_env" \
		SCANNER_PATH="$SCANNER" \
		bash -c "$(run_scan_stub_script)" 2>&1
	return $?
}

# ---------------------------------------------------------------------------
# Test 4: stale → file exactly one alert
# ---------------------------------------------------------------------------
echo "Testing: scan on stale dashboard files alert"
run_scan_with_stubs "$STALE_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 1 )); then
	pass "stale dashboard → exactly 1 alert filed"
else
	fail "stale dashboard alert count" \
		"expected 1, got $created_count; calls:\n$(cat "$calls_file")"
fi

# Assert operational incidents cannot enter the code-worker dispatch queue.
if grep -q 'no-auto-dispatch' "$calls_file" \
	&& grep -q 'operator:testrunner' "$calls_file" \
	&& grep -q 'priority:high' "$calls_file" \
	&& ! grep -q 'review-followup' "$calls_file" \
	&& ! grep -q -- '--label auto-dispatch' "$calls_file"; then
	pass "alert is operator-owned and non-dispatchable"
else
	fail "alert labelling" "calls:\n$(cat "$calls_file")"
fi

alert_body="${TMP}/alert-body.md"
home_marker='~'
if grep -q 'macOS / launchd:' "$alert_body" \
	&& grep -q 'launchctl list | grep -i aidevops-stats-wrapper' "$alert_body" \
	&& grep -q 'Linux / systemd user timers:' "$alert_body" \
	&& grep -q 'systemctl --user status aidevops-stats-wrapper.timer --no-pager' "$alert_body" \
	&& grep -q 'systemctl --user status aidevops-stats-wrapper.service --no-pager' "$alert_body" \
	&& grep -q "systemctl --user list-timers --all --no-pager 'aidevops\*'" "$alert_body" \
	&& grep -q "${home_marker}/.config/systemd/user/aidevops-stats-wrapper\.\*" "$alert_body" \
	&& grep -q 'Linux missing or inactive systemd timer' "$alert_body"; then
	pass "alert body includes macOS launchd and Linux systemd remediation"
else
	fail "alert body scheduler remediation" "body:\n$(cat "$alert_body")"
fi

if grep -q '<!-- aidevops:dashboard-freshness-incident:last_refresh=' "$alert_body"; then
	pass "alert body records durable last_refresh incident fingerprint"
else
	fail "incident fingerprint" "body:\n$(cat "$alert_body")"
fi

# ---------------------------------------------------------------------------
# Test 5: dedup — existing open alert → no second alert
# ---------------------------------------------------------------------------
echo "Testing: existing-alert dedup"
run_scan_with_stubs "$STALE_BODY" 1 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )); then
	pass "stale dashboard with open alert → no duplicate alert"
else
	fail "dedup violated: created $created_count alerts" \
		"calls:\n$(cat "$calls_file")"
fi

issue_list_call="$(grep '^api --paginate repos/test/repo/issues?state=open&per_page=100 ' "$calls_file" || true)"
if [[ -n "$issue_list_call" ]] \
	&& [[ "$issue_list_call" != *"--label"* ]] \
	&& [[ "$issue_list_call" != *"--search"* ]] \
	&& [[ "$issue_list_call" == *"--paginate"* ]] \
	&& [[ "$issue_list_call" == *"--jq"* ]] \
	&& [[ "$issue_list_call" != *"--limit"* ]] \
	&& [[ "$issue_list_call" != *"--json"* ]]; then
	pass "dedup lookup paginates open titles via gh api"
else
	fail "dedup lookup query shape" \
		"expected gh api --paginate title query without --limit/--label/--search; calls:\n$(cat "$calls_file")"
fi

if grep -q -- 'jq -r --arg prefix' "$SCANNER" \
	&& grep -q -- '--arg suffix' "$SCANNER" \
	&& grep -q -- '--arg marker' "$SCANNER" \
	&& ! grep -q -- '--jq.*starts' "$SCANNER" \
	&& ! grep -q -- "jq -r --arg prefix.*2>/dev/null" "$SCANNER"; then
	pass "dedup jq filter binds shell values with --arg and leaves stderr visible"
else
	fail "dedup jq safety shape" \
		"expected jq --arg bindings without gh --jq interpolation or jq stderr suppression"
fi

# ---------------------------------------------------------------------------
# Test 7: fresh body → no alert
# ---------------------------------------------------------------------------
echo "Testing: fresh dashboard → no alert"
run_scan_with_stubs "$FRESH_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )); then
	pass "fresh dashboard → no alert filed"
else
	fail "fresh dashboard triggered alert" \
		"calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 8: fresh body with generated alert → close recovered alert
# ---------------------------------------------------------------------------
echo "Testing: fresh dashboard closes recovered alert"
run_scan_with_stubs "$FRESH_BODY" 1 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
comment_count=$(grep -c '^issue comment 99 ' "$calls_file" 2>/dev/null || true)
close_count=$(grep -c '^issue close 99 ' "$calls_file" 2>/dev/null || true)
[[ "$comment_count" =~ ^[0-9]+$ ]] || comment_count=0
[[ "$close_count" =~ ^[0-9]+$ ]] || close_count=0

if (( comment_count == 1 && close_count == 1 )); then
	pass "fresh dashboard with open alert → comment + close"
else
	fail "recovered alert close" \
		"comment=$comment_count close=$close_count; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 8b: closed dashboard → no alert even if body is stale
# ---------------------------------------------------------------------------
echo "Testing: closed stale dashboard is ignored"
run_scan_with_stubs "$STALE_BODY" 0 "export DASHBOARD_STATE=CLOSED" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )) \
	&& grep -q 'Dashboard test/repo#424242 is closed — skipping stale scan' \
		"${HOME_ISO}/.aidevops/logs/dashboard-freshness.log"; then
	pass "closed stale dashboard → no alert filed"
else
	fail "closed stale dashboard skip" \
		"created=$created_count; calls:\n$(cat "$calls_file"); log:\n$(cat "${HOME_ISO}/.aidevops/logs/dashboard-freshness.log")"
fi

# ---------------------------------------------------------------------------
# Test 9: cadence gate — second scan within interval short-circuits
# ---------------------------------------------------------------------------
echo "Testing: cadence gate suppresses rapid re-scan"
# First run updates last-scan; second run (without --force) should exit
# immediately with no `gh` calls at all.
now_epoch=$(date -u +%s)
printf '%d' "$now_epoch" \
	>"${HOME_ISO}/.aidevops/cache/dashboard-freshness/last-scan"

calls_file="${TMP}/gh-calls.log"
: >"$calls_file"

# Intentionally don't pass --force; invoke scanner directly
HOME="$HOME_ISO" \
	REPOS_JSON="${HOME_ISO}/.config/aidevops/repos.json" \
	DASHBOARD_FRESHNESS_SCAN_INTERVAL="3600" \
	bash -c '
		gh() { printf "%s\n" "$*" >> "'"$calls_file"'"; return 0; }
		export -f gh
		exec bash "'"$SCANNER"'" scan
	' >/dev/null 2>&1

calls=$(wc -l <"$calls_file" | tr -d ' ')
if (( calls == 0 )); then
	pass "cadence gate → zero gh calls within interval"
else
	fail "cadence gate leaked ${calls} gh calls" \
		"calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 10: stale body with missing-marker alert → close mismatch, file stale
# ---------------------------------------------------------------------------
echo "Testing: stale dashboard closes missing-marker alert before stale alert"
run_scan_with_stubs "$STALE_BODY" 1 "" "missing" >/dev/null
calls_file="${TMP}/gh-calls.log"
comment_count=$(grep -c '^issue comment 99 ' "$calls_file" 2>/dev/null || true)
close_count=$(grep -c '^issue close 99 ' "$calls_file" 2>/dev/null || true)
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
list_count=$(grep -c '^api --paginate repos/test/repo/issues?state=open&per_page=100 ' "$calls_file" 2>/dev/null || true)
[[ "$comment_count" =~ ^[0-9]+$ ]] || comment_count=0
[[ "$close_count" =~ ^[0-9]+$ ]] || close_count=0
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0
[[ "$list_count" =~ ^[0-9]+$ ]] || list_count=0

if (( comment_count == 1 && close_count == 1 && created_count == 1 && list_count == 1 )); then
	pass "stale dashboard with missing-marker alert → close mismatch + file stale using one paginated issue fetch"
else
	fail "stale dashboard missing-marker recovery" \
		"comment=$comment_count close=$close_count created=$created_count list=$list_count; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 11: failed open issue list logs an error and preserves JSON shape
# ---------------------------------------------------------------------------
echo "Testing: open issue list failure logs recovery error"
run_scan_with_stubs "$STALE_BODY" 0 "export GH_ISSUE_LIST_FAIL=1" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 1 )) \
	&& grep -q 'Failed to list open issues for dashboard freshness recovery in test/repo' \
		"${HOME_ISO}/.aidevops/logs/dashboard-freshness.log" \
	&& ! grep -q 'parse error' "${HOME_ISO}/.aidevops/logs/dashboard-freshness.log" \
	&& grep -q 'issue_list_json="\[\]"' "$SCANNER"; then
	pass "open issue list failure → logged error and keeps empty JSON fallback"
else
	fail "open issue list failure logging" \
		"created=$created_count; calls:\n$(cat "$calls_file"); log:\n$(cat "${HOME_ISO}/.aidevops/logs/dashboard-freshness.log")"
fi

# ---------------------------------------------------------------------------
# Test 12: missing local cache falls back to source:health-dashboard issues
# ---------------------------------------------------------------------------
echo "Testing: source health-dashboard fallback without local cache"
rm -f "$HEALTH_CACHE"
run_scan_with_stubs "$STALE_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 1 )) \
	&& grep -q '^api --paginate repos/test/repo/issues?state=open&labels=source%3Ahealth-dashboard,supervisor&per_page=100 ' "$calls_file" \
	&& grep -q 'operator:testrunner' "$calls_file"; then
	pass "missing cache → current supervisor dashboard fallback scans dashboard"
else
	fail "source health-dashboard fallback" \
		"created=$created_count; calls:\n$(cat "$calls_file")"
fi
printf '%s\n' 424242 >"$HEALTH_CACHE"

# ---------------------------------------------------------------------------
# Test 12a: local cache discovery still reconciles the authenticated remote
# dashboard so a historical cache cannot hide the active surface.
# ---------------------------------------------------------------------------
echo "Testing: cached dashboard still reconciles current remote dashboard"
run_scan_with_stubs "$STALE_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
remote_dashboard_list_count=$(grep -c '^api --paginate repos/test/repo/issues?state=open&labels=source%3Ahealth-dashboard,supervisor&per_page=100 ' "$calls_file" 2>/dev/null || true)
[[ "$remote_dashboard_list_count" =~ ^[0-9]+$ ]] || remote_dashboard_list_count=0

if (( remote_dashboard_list_count == 1 )); then
	pass "local cache retains current source health-dashboard reconciliation"
else
	fail "cached dashboard reconciliation" "expected one remote dashboard listing; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 12b: a dashboard for a different supervisor is ignored when no local
# cache exists, preventing stale alerts for inactive historical operators.
# ---------------------------------------------------------------------------
echo "Testing: historical supervisor dashboard is ignored"
rm -f "$HEALTH_CACHE"
run_scan_with_stubs "$STALE_BODY" 0 "export DASHBOARD_TITLE='[Supervisor:historical] stale'" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )); then
	pass "historical supervisor dashboard without operator label → no alert"
else
	fail "historical supervisor dashboard ignored" \
		"created=$created_count; calls:\n$(cat "$calls_file")"
fi
printf '%s\n' 424242 >"$HEALTH_CACHE"

# ---------------------------------------------------------------------------
# Test 12c: local cache for another operator is ignored
# ---------------------------------------------------------------------------
echo "Testing: local cache dashboard operator is validated"
run_scan_with_stubs "$STALE_BODY" 0 "export DASHBOARD_OPERATOR=historical" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )) \
	&& grep -q 'does not belong to operator:testrunner' "${HOME_ISO}/.aidevops/logs/dashboard-freshness.log"; then
	pass "historical local cache dashboard → no alert"
else
	fail "local cache operator validation" \
		"created=$created_count; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 12d: contributor health dashboards are ignored
# ---------------------------------------------------------------------------
echo "Testing: contributor dashboard is ignored"
run_scan_with_stubs "$STALE_BODY" 0 "export DASHBOARD_TITLE='[Contributor:testrunner] stale'; export DASHBOARD_ROLE_LABEL=contributor" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )) \
	&& grep -q 'Dashboard test/repo#424242 is not a supervisor dashboard — skipping stale scan' \
		"${HOME_ISO}/.aidevops/logs/dashboard-freshness.log" \
	&& grep -q 'startswith("\[Supervisor:")' "$SCANNER"; then
	pass "contributor dashboard → no stale alert filed"
else
	fail "contributor dashboard skip" \
		"created=$created_count; calls:\n$(cat "$calls_file"); log:\n$(cat "${HOME_ISO}/.aidevops/logs/dashboard-freshness.log")"
fi

# ---------------------------------------------------------------------------
# Test 13: unchanged closed incident is reopened instead of duplicated
# ---------------------------------------------------------------------------
echo "Testing: closed unchanged incident is reopened"
run_scan_with_stubs "$STALE_BODY" 0 "export INCIDENT_EXISTS=1; export INCIDENT_STATE=closed" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
reopen_count=$(grep -c '^issue reopen 98 ' "$calls_file" 2>/dev/null || true)
edit_count=$(grep -c '^issue edit 98 ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0
[[ "$reopen_count" =~ ^[0-9]+$ ]] || reopen_count=0
[[ "$edit_count" =~ ^[0-9]+$ ]] || edit_count=0

if (( created_count == 0 && reopen_count == 1 && edit_count == 1 )); then
	pass "closed unchanged incident → reopen and normalize labels"
else
	fail "closed incident reuse" \
		"created=$created_count reopen=$reopen_count edit=$edit_count; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 14: failed all-state incident lookup fails closed without duplication
# ---------------------------------------------------------------------------
echo "Testing: incident lookup failure fails closed"
run_scan_with_stubs "$STALE_BODY" 0 "export INCIDENT_SEARCH_FAIL=1" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 0 )) \
	&& grep -q 'Incident dedup unavailable for test/repo#424242' "${HOME_ISO}/.aidevops/logs/dashboard-freshness.log"; then
	pass "incident lookup failure → no potentially duplicate alert"
else
	fail "incident lookup fail-closed" \
		"created=$created_count; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Test 15: source shape for shared recovered-alert helper and cached issue list
# ---------------------------------------------------------------------------
echo "Testing: recovered-alert source shape"
if grep -q '^_close_recovered_alerts_for_kind()' "$SCANNER" \
	&& grep -q "_close_recovered_alerts_for_kind \"\$ALERT_KIND_ANY\"" "$SCANNER" \
	&& grep -q "_close_recovered_alerts_for_kind \"\$ALERT_KIND_MISSING\"" "$SCANNER" \
	&& grep -q "local open_issues_json=\"\${7:-}\"" "$SCANNER" \
	&& grep -q "_open_alert_numbers_for_kind \"\$kind\" \"\$slug\" \"\$dash_issue\" \"\$open_issues_json\"" "$SCANNER"; then
	pass "recovered alert close paths share helper and optional issue-list cache"
else
	fail "recovered-alert source shape" \
		"expected shared helper with stale/missing wrappers and optional open_issues_json"
fi

# ---------------------------------------------------------------------------
# Test 16: missing-marker body → alerts with MISSING title
# ---------------------------------------------------------------------------
echo "Testing: missing-marker body files alert"
run_scan_with_stubs "$MISSING_BODY" 0 "" >/dev/null
calls_file="${TMP}/gh-calls.log"
created_count=$(grep -c '^issue create ' "$calls_file" 2>/dev/null || true)
[[ "$created_count" =~ ^[0-9]+$ ]] || created_count=0

if (( created_count == 1 )) && grep -q 'missing last_refresh marker' "$calls_file"; then
	pass "missing-marker body → alert with descriptive title"
else
	fail "missing-marker alert" \
		"created=$created_count; calls:\n$(cat "$calls_file")"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
if (( TESTS_FAILED == 0 )); then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
