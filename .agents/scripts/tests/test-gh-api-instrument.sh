#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Regression test for t2902 / GH#21043 / GH#27769: logical gh events and real
# transport attempts remain separately replayable, bounded, privacy-safe, and
# backward-compatible with legacy records.
# =============================================================================
#
# Background: t2902 added per-call-site instrumentation to identify the
# heavy GraphQL consumers that were draining the budget despite t2574 +
# t2689 REST fallbacks. The recorder must be:
#   (a) cheap (one append per call, fail-open if log path is unwritable),
#   (b) deterministic in aggregation (sorted keys, stable schema),
#   (c) reachable from every gh wrapper site (sourced from
#       shared-gh-wrappers.sh after the rest-fallback include).
#
# This test exercises all three.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0

# Use a per-test temp dir so we don't pollute the host's instrumentation log.
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

export AIDEVOPS_GH_API_LOG="$TMPDIR/gh-api-calls.log"
export AIDEVOPS_GH_API_REPORT="$TMPDIR/report.json"
export AIDEVOPS_GH_API_EVIDENCE="$TMPDIR/evidence.json"
unset AIDEVOPS_GH_QUOTA_COST AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS

assert_eq() {
	local label="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $label"
	echo "    expected: $expected"
	echo "    actual:   $actual"
	FAIL=$((FAIL + 1))
	return 1
}

file_mode() {
	local path="$1"
	local platform=""
	platform=$(uname -s) || return 1
	case "$platform" in
	Linux*) stat -c '%a' "$path" || return 1 ;;
	Darwin* | FreeBSD*) stat -f '%Lp' "$path" || return 1 ;;
	*) return 1 ;;
	esac
	return 0
}

assert_file_exists() {
	local label="$1"
	local path="$2"
	if [[ -f "$path" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $label (missing: $path)"
	FAIL=$((FAIL + 1))
	return 1
}

assert_path_absent() {
	local label="$1"
	local path="$2"
	if [[ ! -e "$path" && ! -L "$path" ]]; then
		echo "  PASS: $label"
		PASS=$((PASS + 1))
		return 0
	fi
	echo "  FAIL: $label (unexpected path: $path)"
	FAIL=$((FAIL + 1))
	return 1
}

echo "Test: gh-api-instrument.sh recording and aggregation"
echo "===================================================="
echo ""

# --- Test 1: source instrumentation directly and record a few calls ----
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
# shellcheck source=../gh-quota-attribution-lib.sh
source "${PARENT_DIR}/gh-quota-attribution-lib.sh"

gh_record_call rest test-instrument
gh_record_call graphql test-instrument
gh_record_call search-graphql test-instrument
gh_record_call search-rest test-instrument
gh_record_call rest test-instrument
gh_record_call rest test-instrument github-app rest-core rest-preferred 4999

assert_file_exists "log file created" "$AIDEVOPS_GH_API_LOG"

line_count=$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')
assert_eq "log has 6 lines" "6" "$line_count"

# --- Test 2: aggregate and validate JSON shape -------------------------
gh_aggregate_calls

assert_file_exists "report file created" "$AIDEVOPS_GH_API_REPORT"
report_mode=$(file_mode "$AIDEVOPS_GH_API_REPORT")
assert_eq "atomic report is private" "600" "$report_mode"

if ! jq -e '.' "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1; then
	echo "  FAIL: report is not valid JSON"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: report is valid JSON"
	PASS=$((PASS + 1))
fi

total_calls=$(jq -r '._meta.total_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "report total_calls = 6" "6" "$total_calls"

rest_count=$(jq -r '.by_caller["test-instrument"].rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "rest_calls = 3" "3" "$rest_count"

graphql_count=$(jq -r '.by_caller["test-instrument"].graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "graphql_calls = 1" "1" "$graphql_count"

search_graphql_count=$(jq -r '.by_caller["test-instrument"].search_graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "search_graphql_calls = 1" "1" "$search_graphql_count"

search_rest_count=$(jq -r '.by_caller["test-instrument"].search_rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "search_rest_calls = 1" "1" "$search_rest_count"

app_auth_count=$(jq -r '.by_auth_mode["github-app"].total' "$AIDEVOPS_GH_API_REPORT")
assert_eq "github-app auth count = 1" "1" "$app_auth_count"

rest_core_count=$(jq -r '.by_api_pool["rest-core"].total' "$AIDEVOPS_GH_API_REPORT")
assert_eq "rest-core pool count = 3" "3" "$rest_core_count"

budget_min=$(jq -r '.budget_by_pool["rest-core"].min_remaining' "$AIDEVOPS_GH_API_REPORT")
assert_eq "rest-core budget min recorded" "4999" "$budget_min"

# --- Test 3: trim respects max-lines threshold ------------------------
# Set a tiny max so we trigger a trim with our 6-line log.
export AIDEVOPS_GH_API_LOG_MAX_LINES=4
# Re-source so the env override is picked up by the GH_API_LOG_MAX_LINES
# constant (it's evaluated at source time).
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_trim_log
trimmed_count=$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')
# Bounded retention keeps at most the configured maximum.
assert_eq "trim retained max lines" "4" "$trimmed_count"

# --- Test 4: clear wipes both log and report --------------------------
gh_clear_log
if [[ -f "$AIDEVOPS_GH_API_LOG" ]]; then
	echo "  FAIL: clear left log behind: $AIDEVOPS_GH_API_LOG"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: clear removed log"
	PASS=$((PASS + 1))
fi
if [[ -f "$AIDEVOPS_GH_API_REPORT" ]]; then
	echo "  FAIL: clear left report behind: $AIDEVOPS_GH_API_REPORT"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: clear removed report"
	PASS=$((PASS + 1))
fi
if [[ -f "$AIDEVOPS_GH_API_EVIDENCE" ]]; then
	echo "  FAIL: clear left evidence behind: $AIDEVOPS_GH_API_EVIDENCE"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: clear removed evidence"
	PASS=$((PASS + 1))
fi

# --- Test 5: integration via shared-gh-wrappers.sh ---------------------
# Sourcing the wrapper must make gh_record_call available — that's the
# integration path the REST translators rely on.
unset _SHARED_GH_WRAPPERS_LOADED _SHARED_GH_WRAPPERS_REST_FALLBACK_LOADED _GH_API_INSTRUMENT_LOADED
# shellcheck source=../shared-gh-wrappers.sh
source "${PARENT_DIR}/shared-gh-wrappers.sh"

if type -t gh_record_call >/dev/null 2>&1; then
	echo "  PASS: gh_record_call defined after sourcing shared-gh-wrappers.sh"
	PASS=$((PASS + 1))
else
	echo "  FAIL: gh_record_call NOT defined after sourcing shared-gh-wrappers.sh"
	FAIL=$((FAIL + 1))
fi

# --- Test 6: disable env var makes record a no-op ---------------------
gh_clear_log
AIDEVOPS_GH_API_INSTRUMENT_DISABLE=1 gh_record_call rest test-disabled
if [[ -f "$AIDEVOPS_GH_API_LOG" ]]; then
	echo "  FAIL: disabled record still wrote log"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: disabled record is a no-op"
	PASS=$((PASS + 1))
fi

# --- Test 7: explicit call-site names partition coarse callers ----------
unset AIDEVOPS_GH_API_INSTRUMENT_DISABLE
gh_clear_log
gh_record_call rest pulse_batch_prefetch_rate_limit
gh_record_call search-graphql pulse_batch_prefetch_search_issues
gh_record_call search-graphql pulse_batch_prefetch_search_prs
gh_record_call rest events_tickle_events
gh_aggregate_calls

rate_limit_count=$(jq -r '.by_caller["pulse_batch_prefetch_rate_limit"].rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: rate-limit REST call counted separately" "1" "$rate_limit_count"

search_issue_count=$(jq -r '.by_caller["pulse_batch_prefetch_search_issues"].search_graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: issue search counted separately" "1" "$search_issue_count"

search_pr_count=$(jq -r '.by_caller["pulse_batch_prefetch_search_prs"].search_graphql_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: PR search counted separately" "1" "$search_pr_count"

tickle_count=$(jq -r '.by_caller["events_tickle_events"].rest_calls' "$AIDEVOPS_GH_API_REPORT")
assert_eq "explicit caller: events tickle REST call counted separately" "1" "$tickle_count"

# --- Test 8: HOME-less temp fallback is owned and private -------------
unset _GH_API_INSTRUMENT_LOADED AIDEVOPS_GH_API_LOG AIDEVOPS_GH_API_REPORT
FAKE_BIN="$TMPDIR/fake-bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/getent" <<'EOF_GETENT'
#!/usr/bin/env bash
exit 2
EOF_GETENT
chmod +x "$FAKE_BIN/getent"
FALLBACK_TMP="$TMPDIR/fallback-root"
set +e
PATH="$FAKE_BIN:$PATH" HOME='' TMPDIR="$FALLBACK_TMP" USER="ghapitest" bash -c '
	set -euo pipefail
	# shellcheck source=../gh-api-instrument.sh
	source "$1"
	gh_record_call rest fallback-test
	mode=$(stat -c '%a' "$TMPDIR/aidevops-$USER" 2>/dev/null || stat -f '%Lp' "$TMPDIR/aidevops-$USER")
	[[ "$mode" == "700" ]]
	[[ -f "$TMPDIR/aidevops-$USER/.aidevops/logs/gh-api-calls.log" ]]
' _ "${PARENT_DIR}/gh-api-instrument.sh"
fallback_status="$?"
set -e
assert_eq "HOME-less temp fallback is private" "0" "$fallback_status"

# --- Test 9: HOME-less temp fallback rejects pre-created symlink ------
unset _GH_API_INSTRUMENT_LOADED AIDEVOPS_GH_API_LOG AIDEVOPS_GH_API_REPORT
SYMLINK_TMP="$TMPDIR/symlink-root"
SYMLINK_TARGET="$TMPDIR/symlink-target"
mkdir -p "$SYMLINK_TMP" "$SYMLINK_TARGET"
ln -s "$SYMLINK_TARGET" "$SYMLINK_TMP/aidevops-ghapitest"
set +e
PATH="$FAKE_BIN:$PATH" HOME='' TMPDIR="$SYMLINK_TMP" USER="ghapitest" bash -c '
	set -euo pipefail
	# shellcheck source=../gh-api-instrument.sh
	source "$1"
	gh_record_call rest symlink-fallback-test
	[[ "${AIDEVOPS_GH_API_INSTRUMENT_DISABLE:-0}" == "1" ]]
	[[ ! -e "$TMPDIR/aidevops-$USER/.aidevops/logs/gh-api-calls.log" ]]
' _ "${PARENT_DIR}/gh-api-instrument.sh"
symlink_status="$?"
set -e
assert_eq "HOME-less temp fallback rejects symlink" "0" "$symlink_status"

# --- Test 10: missing lock tools fail open without stderr noise --------
saved_path="$PATH"
mkdir -p "$TMPDIR/no-lock-tools"
set +e
# shellcheck disable=SC2123 # Intentional empty-tool fixture for fail-open coverage.
PATH="$TMPDIR/no-lock-tools"
_gh_log_lock_acquire 2>"$TMPDIR/no-lock-tools.stderr"
lock_status=$?
PATH="$saved_path"
set -e
assert_eq "missing lock tools fail open" "1" "$lock_status"
lock_stderr_bytes=$(wc -c <"$TMPDIR/no-lock-tools.stderr" | tr -d ' ')
assert_eq "missing lock tools stay silent" "0" "$lock_stderr_bytes"

# --- Test 10b: abandoned empty locks recover instead of wedging telemetry --
export AIDEVOPS_GH_API_LOG="$TMPDIR/stale-lock-calls.log"
export AIDEVOPS_GH_API_REPORT="$TMPDIR/stale-lock-report.json"
export AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES=0
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
assert_eq "empty lock grace accepts an environment override" "0" "$_GH_API_EMPTY_LOCK_GRACE_TRIES"
invalid_grace=$(AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES=invalid bash -c '
	# shellcheck source=/dev/null
	source "$1"
	printf "%s\n" "$_GH_API_EMPTY_LOCK_GRACE_TRIES"
' _ "${PARENT_DIR}/gh-api-instrument.sh")
assert_eq "invalid empty lock grace uses the default" "100" "$invalid_grace"
gh_clear_log
mkdir "${GH_API_LOG}.lock"
gh_record_call rest stale-empty-lock-test
assert_eq "stale empty lock permits the next record" "1" "$(wc -l <"$GH_API_LOG" | tr -d ' ')"
if [[ -d "${GH_API_LOG}.lock" ]]; then
	echo "  FAIL: stale empty telemetry lock survived recovery"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: stale empty telemetry lock was removed"
	PASS=$((PASS + 1))
fi

mkdir "${GH_API_LOG}.lock"
printf '%s\n' 'not-a-pid' >"${GH_API_LOG}.lock/pid"
_GH_API_EMPTY_LOCK_GRACE_TRIES=100
malformed_lock_status=0
_gh_log_lock_reclaim "${GH_API_LOG}.lock" 0 || malformed_lock_status=$?
assert_eq "malformed PID lock is reclaimed without the empty-lock grace" "0" "$malformed_lock_status"
gh_record_call rest stale-malformed-lock-test
assert_eq "stale malformed lock permits the next record" "2" "$(wc -l <"$GH_API_LOG" | tr -d ' ')"

mkdir "${GH_API_LOG}.lock"
printf '%s\n' '999999999' >"${GH_API_LOG}.lock/pid"
_GH_API_EMPTY_LOCK_GRACE_TRIES=100
dead_lock_status=0
_gh_log_lock_reclaim "${GH_API_LOG}.lock" 0 || dead_lock_status=$?
assert_eq "dead PID lock is reclaimed without the empty-lock grace" "0" "$dead_lock_status"

mkdir "${GH_API_LOG}.lock"
printf '%s\n' "${BASHPID:-$$}" >"${GH_API_LOG}.lock/pid"
live_lock_status=0
_gh_log_lock_reclaim "${GH_API_LOG}.lock" 100 || live_lock_status=$?
assert_eq "live PID lock is not reclaimed" "1" "$live_lock_status"
rm -f "${GH_API_LOG}.lock/pid"
rmdir "${GH_API_LOG}.lock"

# --- Test 10c: issue sync keeps the framework gh shim first on PATH -------
issue_sync_scripts_dir="$(cd "$PARENT_DIR" && pwd)"
issue_sync_probe="$TMPDIR/issue-sync-path-probe.sh"
cat >"$issue_sync_probe" <<'EOF_ISSUE_SYNC_PROBE'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=../issue-sync-helper.sh
source "$ISSUE_SYNC_HELPER" >/dev/null
source "$ISSUE_SYNC_HELPER" >/dev/null
printf '%s\n' "$PATH"
EOF_ISSUE_SYNC_PROBE
issue_sync_path=$(ISSUE_SYNC_HELPER="${PARENT_DIR}/issue-sync-helper.sh" PATH="$FAKE_BIN:$saved_path" "$BASH" "$issue_sync_probe")
issue_sync_path_head="${issue_sync_path%%:*}"
assert_eq "issue sync preserves framework gh shim precedence" "$issue_sync_scripts_dir" "$issue_sync_path_head"
case "$issue_sync_path" in
:* | *::* | *:) issue_sync_empty_component="yes" ;;
*) issue_sync_empty_component="no" ;;
esac
assert_eq "issue sync removes empty PATH components" "no" "$issue_sync_empty_component"
case ":$issue_sync_path:" in
*":$FAKE_BIN:"*) issue_sync_caller_shim="present" ;;
*) issue_sync_caller_shim="missing" ;;
esac
assert_eq "issue sync preserves caller-provided shim directories" "present" "$issue_sync_caller_shim"
issue_sync_path_tail="${issue_sync_path#*:}"
case ":$issue_sync_path_tail:" in
*":$issue_sync_scripts_dir:"*) issue_sync_duplicate_framework_dir="yes" ;;
*) issue_sync_duplicate_framework_dir="no" ;;
esac
assert_eq "re-sourcing issue sync does not duplicate its scripts directory" "no" "$issue_sync_duplicate_framework_dir"

# Restore per-test overrides for summary diagnostics if future tests append.
export AIDEVOPS_GH_API_LOG="$TMPDIR/gh-api-calls.log"
export AIDEVOPS_GH_API_REPORT="$TMPDIR/report.json"
unset AIDEVOPS_GH_API_EMPTY_LOCK_GRACE_TRIES

# --- Test 11: exact replay separates events, attempts, pages, and retries --
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log

AIDEVOPS_GH_LOGICAL_ID=logical-replay gh_record_call rest replay-caller github-app rest-core rest-selected 4998
gh_record_attempt rest replay-caller logical-replay attempt-rest-1 1 0 success 200 120 1 github-app rest-core rest-selected 4998
gh_record_attempt rest replay-caller logical-replay attempt-rest-2 2 0 success 200 80 1 github-app rest-core rest-selected 4997
gh_record_attempt graphql replay-caller logical-replay attempt-graphql-1 1 1 error 403 40 1 gh-pat graphql rest-fallback-graphql 0
AIDEVOPS_GH_LOGICAL_ID=logical-cache gh_record_call other replay-cache unknown other hit ""
now=$(date +%s)
printf '%s\tlegacy-caller\trest\tgh-pat\trest-core\tlegacy-route\t4996\n' "$now" >>"$AIDEVOPS_GH_API_LOG"
# Duplicate IDs are rejected from replay totals and surfaced in metadata.
gh_record_attempt rest replay-caller logical-replay attempt-rest-2 2 0 success 200 80 1 github-app rest-core rest-selected 4997
printf 'malformed legacy row\n' >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls

assert_eq "schema version = 2" "2" "$(jq -r '._meta.schema_version' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "attempt replay excludes duplicate ID" "3" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "logical routing events remain separate" "1" "$(jq -r '._meta.logical_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "cache-only decision has zero attempts" "0" "$(jq -r '.by_caller["replay-cache"].attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "cache event counted separately" "1" "$(jq -r '._meta.cache_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "legacy row remains a logical observation" "1" "$(jq -r '._meta.legacy_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "one retry linked to logical operation" "1" "$(jq -r '._meta.retries' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "three explicit request pages" "3" "$(jq -r '._meta.pages' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "one additional page" "1" "$(jq -r '._meta.additional_pages' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "quota replay sum" "3" "$(jq -r '._meta.known_quota_cost' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "elapsed replay sum" "240" "$(jq -r '._meta.elapsed_ms' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "REST attempts grouped by path" "2" "$(jq -r '.by_path.rest.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "attempts grouped by auth pool" "2" "$(jq -r '.by_api_pool["rest-core"].attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "duplicate attempt ID surfaced" "1" "$(jq -r '._meta.duplicate_attempt_ids' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "duplicate makes exactness false" "false" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "malformed row surfaced" "1" "$(jq -r '._meta.malformed_records' "$AIDEVOPS_GH_API_REPORT")"

# --- Test 11: command arguments remain private and exit status is preserved --
gh_clear_log
gh_run_transport_attempt rest privacy-caller logical-private 1 0 -- true \
	'endpoint-private?token=do-not-log' 'Authorization: bearer do-not-log' '--body=private-payload'
set +e
gh_run_transport_attempt graphql privacy-caller logical-private 1 1 -- false
transport_status=$?
set -e
assert_eq "transport failure status preserved" "1" "$transport_status"
if grep -Eq 'do-not-log|private-payload|Authorization|endpoint-private' "$AIDEVOPS_GH_API_LOG"; then
	echo "  FAIL: transport telemetry exposed command arguments"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: transport telemetry excludes command arguments"
	PASS=$((PASS + 1))
fi
gh_aggregate_calls
assert_eq "success and failure attempts recorded" "2" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "failed outcome recorded" "1" "$(jq -r '._meta.failed_attempts' "$AIDEVOPS_GH_API_REPORT")"

# --- Test 11b: inferred quota is recorded only after transport success -------
gh_clear_log
AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS=1 \
	gh_run_transport_attempt rest quota-caller logical-quota 1 0 -- true
set +e
AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS=1 \
	gh_run_transport_attempt rest quota-caller logical-quota 1 1 -- false
inferred_failure_status=$?
set -e
AIDEVOPS_GH_QUOTA_COST=3 AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS=1 \
	gh_run_transport_attempt rest quota-caller logical-quota 1 0 -- true
assert_eq "inferred-cost transport failure status preserved" "1" "$inferred_failure_status"
gh_aggregate_calls
assert_eq "successful inferred and explicit costs reconcile" "4" "$(jq -r '._meta.known_quota_cost' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "failed inferred cost remains unknown" "1" "$(jq -r '._meta.unknown_quota_cost_attempts' "$AIDEVOPS_GH_API_REPORT")"

# --- Test 11c: exact-frame capture honours success-only quota costs ----------
exact_success_result="$TMPDIR/exact-success.result"
exact_failure_result="$TMPDIR/exact-failure.result"
exact_success_state="$TMPDIR/exact-success.state"
exact_failure_state="$TMPDIR/exact-failure.state"
: >"$exact_success_result"
: >"$exact_failure_result"
_ghqa_state_write_all "$exact_success_state" 0 1800000000 0 1800000000 0 1800000000
_ghqa_state_write_all "$exact_failure_state" 0 1800000000 0 1800000000 0 1800000000
exact_success_frame=$'frame\t1\t1\t200\tgraphql\t10\t4990\t1800000000\t25'
exact_failure_frame=$'frame\t1\t1\t200\tgraphql\t12\t4988\t1800000000\t25'
exact_success_rc=0
exact_failure_rc=0
set +e
AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS=1 \
	_ghqa_write_complete_frames "$exact_success_result" "$exact_success_state" graphql 1 0 \
	"$exact_success_frame" -- gh api graphql
exact_success_rc=$?
AIDEVOPS_GH_QUOTA_COST_ON_SUCCESS=1 \
	_ghqa_write_complete_frames "$exact_failure_result" "$exact_failure_state" graphql 1 1 \
	"$exact_failure_frame" -- gh api graphql
exact_failure_rc=$?
set -e
assert_eq "exact successful frame writer returns zero" "0" "$exact_success_rc"
assert_eq "exact failed-command frame writer returns zero" "0" "$exact_failure_rc"
assert_eq "exact successful frame records inferred quota" "1" \
	"$(awk -F '\t' 'NR == 1 { print $7 }' "$exact_success_result")"
assert_eq "exact failed frame leaves inferred quota unknown" "x" \
	"$(awk -F '\t' 'NR == 1 { print $7 }' "$exact_failure_result")"

# --- Test 11d: successful native multi-frame REST costs are exact -----------
native_multi_result="$TMPDIR/native-multi.result"
native_multi_state="$TMPDIR/native-multi.state"
native_multi_frames=$'frame\t1\t1\t200\tcore\t500\t4500\t1800000000\t10\nframe\t2\t1\t200\tcore\t501\t4499\t1800000000\t11\nframe\t3\t1\t200\tcore\t502\t4498\t1800000000\t12'
: >"$native_multi_result"
_ghqa_state_write_all "$native_multi_state" 500 1800000000 20 1800000000 0 1800000000
_ghqa_write_complete_frames "$native_multi_result" "$native_multi_state" graphql 1 0 \
	"$native_multi_frames" gh run view 123 --log
assert_eq "native multi-frame REST pages retain separate exact attempts" \
	"rest:1:success:1,rest:2:success:1,rest:3:success:1" \
	"$(awk -F '\t' '{ value = value (value ? "," : "") $2 ":" $3 ":" $4 ":" $7 } END { print value }' "$native_multi_result")"

native_single_result="$TMPDIR/native-single.result"
native_single_state="$TMPDIR/native-single.state"
native_single_frame=$'frame\t1\t1\t200\tcore\t507\t4493\t1800000000\t10'
: >"$native_single_result"
_ghqa_state_write_all "$native_single_state" 500 1800000000 20 1800000000 0 1800000000
_ghqa_write_complete_frames "$native_single_result" "$native_single_state" graphql 1 0 \
	"$native_single_frame" gh auth status
assert_eq "native single-frame REST response has response-owned exact cost" \
	"rest:1:success:1" \
	"$(awk -F '\t' '{ print $2 ":" $3 ":" $4 ":" $7 }' "$native_single_result")"

native_search_result="$TMPDIR/native-search.result"
native_search_state="$TMPDIR/native-search.state"
native_search_frame=$'frame\t1\t1\t200\tsearch\t17\t13\t1800000000\t10'
: >"$native_search_result"
_ghqa_state_write_all "$native_search_state" 500 1800000000 20 1800000000 10 1800000000
_ghqa_write_complete_frames "$native_search_result" "$native_search_state" graphql 1 0 \
	"$native_search_frame" gh search issues attribution
assert_eq "native single-frame search response has response-owned exact cost" \
	"search-rest:1:success:1" \
	"$(awk -F '\t' '{ print $2 ":" $3 ":" $4 ":" $7 }' "$native_search_result")"

native_conditional_result="$TMPDIR/native-conditional.result"
native_conditional_state="$TMPDIR/native-conditional.state"
native_conditional_frames=$'frame\t1\t1\t304\tcore\t500\t4500\t1800000000\t10\nframe\t2\t1\t200\tcore\t501\t4499\t1800000000\t11'
: >"$native_conditional_result"
_ghqa_state_write_all "$native_conditional_state" 500 1800000000 20 1800000000 0 1800000000
_ghqa_write_complete_frames "$native_conditional_result" "$native_conditional_state" graphql 1 0 \
	"$native_conditional_frames" gh run view 123 --log
assert_eq "native conditional REST response preserves exact zero cost" \
	"rest:1:success:0,rest:2:success:1" \
	"$(awk -F '\t' '{ value = value (value ? "," : "") $2 ":" $3 ":" $4 ":" $7 } END { print value }' "$native_conditional_result")"

native_mixed_result="$TMPDIR/native-mixed.result"
native_mixed_state="$TMPDIR/native-mixed.state"
native_mixed_frames=$'frame\t1\t1\t200\tcore\t10\t4990\t1800000000\t10\nframe\t2\t1\t200\tgraphql\t20\t4980\t1800000000\t11'
: >"$native_mixed_result"
_ghqa_state_write_all "$native_mixed_state" 10 1800000000 20 1800000000 0 1800000000
_ghqa_write_complete_frames "$native_mixed_result" "$native_mixed_state" graphql 1 0 \
	"$native_mixed_frames" gh run view 123
assert_eq "native multi-frame inference leaves GraphQL without proof unknown" "1,x" \
	"$(awk -F '\t' '{ value = value (value ? "," : "") $7 } END { print value }' "$native_mixed_result")"

native_failed_result="$TMPDIR/native-failed.result"
native_failed_state="$TMPDIR/native-failed.state"
native_failed_frames=$'frame\t1\t1\t200\tcore\t10\t4990\t1800000000\t10\nframe\t2\t1\t500\tcore\t12\t4988\t1800000000\t11'
: >"$native_failed_result"
_ghqa_state_write_all "$native_failed_state" 10 1800000000 20 1800000000 0 1800000000
_ghqa_write_complete_frames "$native_failed_result" "$native_failed_state" graphql 1 1 \
	"$native_failed_frames" gh run view 123
assert_eq "failed native REST frame remains unknown without counter proof" "1,x" \
	"$(awk -F '\t' '{ value = value (value ? "," : "") $7 } END { print value }' "$native_failed_result")"

# --- Test 12: effective window comes from retained attempt timestamps -----
gh_clear_log
first_ts=$((now - 30))
last_ts=$((now - 10))
printf '%s\twindow-caller\trest\tgh-pat\trest-core\trest-selected\t4999\tv2\tattempt\tlogical-window\tattempt-window-1\t1\t0\tsuccess\t200\t10\t1\n' "$first_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\twindow-caller\trest\tgh-pat\trest-core\trest-selected\t4998\tv2\tattempt\tlogical-window\tattempt-window-2\t2\t0\tsuccess\t200\t20\t1\n' "$last_ts" >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 3600
assert_eq "requested window retained separately" "3600" "$(jq -r '._meta.requested_window_seconds' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "first retained attempt timestamp" "$first_ts" "$(jq -r '._meta.first_retained_ts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "last retained attempt timestamp" "$last_ts" "$(jq -r '._meta.last_retained_ts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "effective window uses observed range" "20" "$(jq -r '._meta.effective_window_seconds' "$AIDEVOPS_GH_API_REPORT")"
assert_file_exists "digest-bound evidence sidecar created" "$AIDEVOPS_GH_API_EVIDENCE"
report_digest=$(python3 -c 'import hashlib,sys;print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$AIDEVOPS_GH_API_REPORT")
evidence_digest=$(jq -r '.transport_sha256' "$AIDEVOPS_GH_API_EVIDENCE")
assert_eq "evidence sidecar is bound to report bytes" "$report_digest" "$evidence_digest"
assert_eq "incomplete production evidence fails closed" "false" "$(jq -r '.complete' "$AIDEVOPS_GH_API_EVIDENCE")"
evidence_mode=$(file_mode "$AIDEVOPS_GH_API_EVIDENCE")
assert_eq "evidence sidecar is private" "600" "$evidence_mode"
rm -f "$AIDEVOPS_GH_API_LOG"
gh_record_call rest invalid-window-caller
gh_aggregate_calls
if [[ -f "$AIDEVOPS_GH_API_EVIDENCE" ]]; then
	echo "  FAIL: invalid aggregate left a stale evidence sidecar"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: invalid aggregate removed stale evidence sidecar"
	PASS=$((PASS + 1))
fi

# --- Test 12b: retained opaque history does not poison a fresh window -------
gh_clear_log
outside_ts=$((now - 120))
inside_ts=$((now - 10))
inside_last_ts=$((now - 5))
printf '%s\topaque-caller\trest\tgh-pat\trest-core\tnative-pagination-opaque\t\tv2\tattempt\tlogical-old\tattempt-shared\t0\t0\tsuccess\t200\t10\t\n' "$outside_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\texact-caller\trest\tgh-pat\trest-core\trest-selected\t\tv2\tattempt\tlogical-new\tattempt-shared\t1\t0\tsuccess\t200\t10\t\n' "$inside_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\texact-caller\trest\tgh-pat\trest-core\trest-selected\t\tv2\tattempt\tlogical-new\tattempt-new\t2\t0\tsuccess\t200\t20\t\n' "$inside_last_ts" >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 60
assert_eq "fresh window excludes retained unknown pages" "0" "$(jq -r '._meta.unknown_page_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "retained unknown page remains auditable" "1" "$(jq -r '._meta.retained_unknown_page_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "old duplicate ID does not poison fresh attempts" "2" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "retained duplicate remains auditable" "1" "$(jq -r '._meta.retained_duplicate_attempt_ids' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh window duplicate count stays scoped" "0" "$(jq -r '._meta.duplicate_attempt_ids' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh exact window ignores old opaque call" "0" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh window first timestamp excludes history" "$inside_ts" "$(jq -r '._meta.first_retained_ts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh window last timestamp excludes history" "$inside_last_ts" "$(jq -r '._meta.last_retained_ts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh effective window excludes history" "5" "$(jq -r '._meta.effective_window_seconds' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fresh window exactness is true" "true" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"

# --- Test 12c: fixed cutoffs exclude concurrent post-cycle appends ----------
gh_clear_log
fixed_end_ts=$((now - 5))
post_cycle_ts=$((fixed_end_ts + 1))
printf "%s\tfixed-caller\trest\tgh-pat\trest-core\trest-selected\t4999\tv2\tattempt\tlogical-fixed\tattempt-fixed-1\t1\t0\tsuccess\t200\t10\t1\n" "$fixed_end_ts" >>"$AIDEVOPS_GH_API_LOG"
printf "%s\tfuture-caller\trest\tgh-pat\trest-core\trest-selected\t4998\tv2\tattempt\tlogical-future\tattempt-future-1\t1\t0\tsuccess\t200\t10\t1\n" "$post_cycle_ts" >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 60 "$fixed_end_ts"
assert_eq "explicit cutoff becomes report timestamp" "$fixed_end_ts" "$(jq -r "._meta.generated_at_ts" "$AIDEVOPS_GH_API_REPORT")"
assert_eq "post-cutoff attempt is excluded" "1" "$(jq -r "._meta.attempted_requests" "$AIDEVOPS_GH_API_REPORT")"
assert_eq "post-cutoff attempt is excluded from retained audit" "1" "$(jq -r "._meta.retained_records" "$AIDEVOPS_GH_API_REPORT")"
assert_eq "fixed report ends at the completed cutoff" "$fixed_end_ts" "$(jq -r "._meta.last_retained_ts" "$AIDEVOPS_GH_API_REPORT")"
if compgen -G "${AIDEVOPS_GH_API_REPORT}.source.*" >/dev/null; then
	echo "  FAIL: aggregate left a private source snapshot behind"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: aggregate removed its private source snapshot"
	PASS=$((PASS + 1))
fi
set +e
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 60 "$((now + 60))"
future_cutoff_status=$?
set -e
assert_eq "future report cutoff is rejected" "1" "$future_cutoff_status"

# --- Test 12d: completed marker timestamp survives a second rollover --------
# Freeze the recorder one second after the cycle cutoff. The bounded override
# must place the marker at the captured cutoff while a later attempt remains
# outside the fixed aggregate. Future overrides still fail closed (GH#28493).
gh_clear_log
rollover_cutoff=$((now - 2))
rollover_append_now=$((rollover_cutoff + 1))
_gh_now_seconds() {
	printf '%s\n' "$rollover_append_now"
	return 0
}
printf "%s\tpre-cycle-caller\trest\tgh-pat\trest-core\trest-selected\t4999\tv2\tattempt\tlogical-pre-cycle\tattempt-before-boundary\t1\t0\tsuccess\t200\t10\t1\n" \
	"$rollover_cutoff" >>"$AIDEVOPS_GH_API_LOG"
gh_record_efficiency_evidence coverage-end "$rollover_cutoff" "$rollover_cutoff"
gh_record_attempt rest rollover-caller logical-rollover attempt-after-cycle 1 0 success 200 10 1 gh-pat rest-core rest-selected 4999
marker_record_ts=$(awk -F'\t' -v decision="evidence:coverage-end:${rollover_cutoff}" '$6 == decision { print $1 }' "$AIDEVOPS_GH_API_LOG")
assert_eq "explicit evidence timestamp matches completed cutoff" "$rollover_cutoff" "$marker_record_ts"
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 60 "$rollover_cutoff"
assert_eq "rollover report retains the aligned coverage marker" "1" "$(jq -r --arg key "evidence:coverage-end:${rollover_cutoff}" '.by_route_decision[$key].evidence_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "rollover report excludes post-cycle attempts" "1" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "rollover report omits the post-cycle caller" "0" "$(jq -r '(.by_caller["rollover-caller"].attempted_requests // 0)' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "rollover report ends at the completed cutoff" "$rollover_cutoff" "$(jq -r '._meta.last_retained_ts' "$AIDEVOPS_GH_API_REPORT")"
set +e
gh_record_efficiency_evidence coverage-end "$((rollover_append_now + 1))" "$((rollover_append_now + 1))"
future_evidence_status=$?
set -e
assert_eq "future evidence timestamp is rejected" "1" "$future_evidence_status"
assert_eq "rejected future evidence is not appended" "3" "$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')"

# Restore the production clock implementation for the remaining tests.
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"

# --- Test 12e: typed evidence and latency completeness stay explicit --------
gh_clear_log
latency_ts=$((now - 5))
gh_record_efficiency_evidence cache.fresh_hits 1
printf '%s\tlatency-caller\trest\tgh-pat\trest-core\trest-selected\t\tv2\tattempt\tlogical-latency\tattempt-latency-1\t1\t0\tsuccess\t200\t10\t\n' "$latency_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\tlatency-caller\trest\tgh-pat\trest-core\trest-selected\t\tv2\tattempt\tlogical-latency\tattempt-latency-2\t2\t0\tsuccess\t200\t30\t\n' "$latency_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\tlatency-caller\trest\tgh-pat\trest-core\trest-selected\t\tv2\tattempt\tlogical-latency\tattempt-latency-3\t3\t0\tsuccess\t200\t20\t\n' "$latency_ts" >>"$AIDEVOPS_GH_API_LOG"
printf '%s\tlatency-caller\trest\tgh-pat\trest-core\trest-selected\t\tv2\tattempt\tlogical-latency\tattempt-latency-4\t4\t0\tsuccess\t200\t\t\n' "$latency_ts" >>"$AIDEVOPS_GH_API_LOG"
gh_aggregate_calls "$AIDEVOPS_GH_API_REPORT" 60
assert_eq "typed evidence is not a logical call" "0" "$(jq -r '._meta.total_calls' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "typed evidence event is counted" "1" "$(jq -r '._meta.evidence_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "typed evidence route remains parseable" "1" "$(jq -r '.by_route_decision["evidence:cache.fresh_hits:1"].evidence_events' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "nearest-rank request p50 uses known samples" "20" "$(jq -r '._meta.request_p50_ms' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "nearest-rank request p95 uses known samples" "30" "$(jq -r '._meta.request_p95_ms' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "missing elapsed values stay explicit" "1" "$(jq -r '._meta.unknown_elapsed_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "peak attempts per minute uses transport attempts" "4" "$(jq -r '._meta.peak_attempts_per_minute' "$AIDEVOPS_GH_API_REPORT")"
invalid_evidence_status=0
gh_record_efficiency_evidence "Invalid Name" 1 || invalid_evidence_status=$?
assert_eq "invalid evidence identifiers are rejected" "1" "$invalid_evidence_status"

# --- Test 12f: CLI reports the actual custom aggregate destination -----------
custom_report="$TMPDIR/custom-report.json"
custom_report_message=$("${PARENT_DIR}/gh-api-instrument.sh" report "$custom_report" 60 2>&1 >/dev/null)
assert_file_exists "CLI custom report is created" "$custom_report"
assert_eq "CLI reports the custom output path" "Wrote $custom_report" "$custom_report_message"

# --- Test 13: time/line/byte retention is atomic and bounded -------------
export AIDEVOPS_GH_API_LOG_MAX_LINES=3
export AIDEVOPS_GH_API_LOG_MAX_BYTES=10000
export AIDEVOPS_GH_API_RETENTION_SECONDS=100
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log
printf '1\told-caller\trest\n' >>"$AIDEVOPS_GH_API_LOG"
for fixture_index in 1 2 3 4; do
	fixture_ts=$((now - 5 + fixture_index))
	printf '%s\tretained-%s\trest\tgh-pat\trest-core\trest-selected\t\tv2\tlogical\tlogical-retained-%s\t\t\t\t\t\t\t\n' \
		"$fixture_ts" "$fixture_index" "$fixture_index" >>"$AIDEVOPS_GH_API_LOG"
done
gh_trim_log
assert_eq "retention applies maximum line count" "3" "$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')"
if grep -q 'old-caller' "$AIDEVOPS_GH_API_LOG"; then
	echo "  FAIL: time retention kept expired record"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: time retention removed expired record"
	PASS=$((PASS + 1))
fi

export AIDEVOPS_GH_API_LOG_MAX_LINES=100
export AIDEVOPS_GH_API_LOG_MAX_BYTES=220
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log
for fixture_index in 1 2 3 4 5; do
	gh_record_call rest "byte-retention-${fixture_index}"
done
gh_trim_log
retained_bytes=$(wc -c <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')
if [[ "$retained_bytes" -le 220 ]]; then
	echo "  PASS: byte retention stayed within bound"
	PASS=$((PASS + 1))
else
	echo "  FAIL: byte retention exceeded bound ($retained_bytes > 220)"
	FAIL=$((FAIL + 1))
fi

# --- Test 14: concurrent append keeps one complete record per writer ------
export AIDEVOPS_GH_API_LOG_MAX_BYTES=10000
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"
gh_clear_log
for fixture_index in 1 2 3 4 5 6 7 8 9 10 11 12; do
	(
		unset _GH_API_INSTRUMENT_LOADED
		# shellcheck source=../gh-api-instrument.sh
		source "${PARENT_DIR}/gh-api-instrument.sh"
		gh_record_attempt rest concurrent-caller "logical-${fixture_index}" "attempt-${fixture_index}" 1 0 success 200 1 1 gh-pat rest-core rest-selected 4999
	) &
done
wait
assert_eq "concurrent append retained all complete records" "12" "$(wc -l <"$AIDEVOPS_GH_API_LOG" | tr -d ' ')"
assert_eq "concurrent attempt IDs remain unique" "12" "$(cut -f11 "$AIDEVOPS_GH_API_LOG" | sort -u | wc -l | tr -d ' ')"

# --- Test 15: the shim records exactly one native transport attempt -------
SHIM_FIXTURE="$TMPDIR/shim-fixture"
NATIVE_FIXTURE="$TMPDIR/native-fixture"
mkdir -p "$SHIM_FIXTURE" "$NATIVE_FIXTURE"
cp "${PARENT_DIR}/gh" "$SHIM_FIXTURE/gh"
cp "${PARENT_DIR}/gh-native-transport-lib.sh" "$SHIM_FIXTURE/gh-native-transport-lib.sh"
cp "${PARENT_DIR}/gh-api-guards-lib.sh" "$SHIM_FIXTURE/gh-api-guards-lib.sh"
cp "${PARENT_DIR}/gh-write-policy-lib.sh" "$SHIM_FIXTURE/gh-write-policy-lib.sh"
cp "${PARENT_DIR}/gh-api-instrument.sh" "$SHIM_FIXTURE/gh-api-instrument.sh"
cp "${PARENT_DIR}/gh-rest-pagination-lib.sh" "$SHIM_FIXTURE/gh-rest-pagination-lib.sh"
chmod +x "$SHIM_FIXTURE/gh"
cat >"$NATIVE_FIXTURE/gh" <<'EOF_NATIVE_GH'
#!/usr/bin/env bash
printf '%s\n' "$@" >>"$NATIVE_ATTEMPT_LOG"
if [[ "${1:-}:${2:-}" == "auth:git-credential" ]]; then
	command cat >"$NATIVE_CREDENTIAL_INPUT"
	printf 'username=fixture\npassword=fixture\n\n'
	exit "${NATIVE_CREDENTIAL_STATUS:-0}"
fi
page=1
jq_requested=0
expect_jq=0
slurp_requested=0
template_requested=0
expect_template=0
for arg in "$@"; do
	if [[ "$expect_jq" -eq 1 ]]; then
		expect_jq=0
		continue
	fi
	if [[ "$expect_template" -eq 1 ]]; then
		expect_template=0
		continue
	fi
	case "$arg" in
	--jq | -q)
		jq_requested=1
		expect_jq=1
		;;
	--jq=* | -q*) jq_requested=1 ;;
	--slurp) slurp_requested=1 ;;
	--template | -t)
		template_requested=1
		expect_template=1
		;;
	--template=* | -t*) template_requested=1 ;;
	*)
		if [[ "$arg" =~ (^|[?\&])page=([0-9]+)($|\&) ]]; then
			page="${BASH_REMATCH[2]}"
		fi
		;;
	esac
done
if [[ "${NATIVE_REJECT_SLURP_FILTERS:-0}" == "1" && "$slurp_requested" -eq 1 \
	&& ("$jq_requested" -eq 1 || "$template_requested" -eq 1) ]]; then
	printf 'the --slurp option is not supported with --jq or --template\n' >&2
	exit "${NATIVE_PREFLIGHT_STATUS:-1}"
fi
if [[ "${NATIVE_PAGINATED_RESPONSE:-0}" == "1" ]]; then
	printf 'HTTP/2.0 200 OK\r\n'
	if [[ "$page" -eq 1 ]]; then
		if [[ "${NATIVE_ENTERPRISE_LINK:-0}" == "1" ]]; then
			printf 'Link: <https://ghe.example/api/v3/repos/fixture/items?per_page=100&page=2>; rel="next"\r\n'
		elif [[ "${NATIVE_COMMA_LINK:-0}" == "1" ]]; then
			printf 'Link: <https://api.github.com/repos/fixture/items?labels=bug,help-wanted&page=2>; rel="next"\r\n'
		elif [[ "${NATIVE_QUERY_REL_ONLY:-0}" == "1" ]]; then
			printf 'Link: <https://api.github.com/repos/fixture/items?per_page=100&page=2&rel=next>; rel="prev"\r\n'
		else
			printf 'Link: <repos/fixture/items?per_page=100&page=2>; rel="next"\r\n'
		fi
	elif [[ "$page" -eq 2 && "${NATIVE_CYCLIC_LINK:-0}" == "1" ]]; then
		printf 'Link: <repos/fixture/items?per_page=100&page=2>; rel="next"\r\n'
	fi
	printf '\r\n'
	if [[ "$jq_requested" -eq 1 ]]; then
		printf '%s\n' "$page"
	elif [[ "${NATIVE_NO_FINAL_NEWLINE:-0}" == "1" ]]; then
		printf '[{"page":%s}]' "$page"
	else
		printf '[{"page":%s}]\n' "$page"
	fi
fi
exit "${NATIVE_ATTEMPT_STATUS:-0}"
EOF_NATIVE_GH
chmod +x "$NATIVE_FIXTURE/gh"
export AIDEVOPS_GH_API_LOG="$TMPDIR/shim-attempts.log"
export NATIVE_ATTEMPT_LOG="$TMPDIR/native-attempts.log"
export NATIVE_CREDENTIAL_INPUT="$TMPDIR/native-credential-input"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"

# Git invokes `gh auth git-credential` as a local stdin/stdout credential
# helper. It must remain byte-compatible without becoming a synthetic GraphQL
# request or an unknown-quota attempt in transport evidence (GH#27777).
credential_request="$TMPDIR/credential-request"
credential_expected_output="$TMPDIR/credential-output.expected"
credential_actual_output="$TMPDIR/credential-output.actual"
printf 'protocol=https\nhost=github.com\n\n' >"$credential_request"
printf 'username=fixture\npassword=fixture\n\n' >"$credential_expected_output"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" \
	"$SHIM_FIXTURE/gh" auth git-credential get \
	<"$credential_request" >"$credential_actual_output"
credential_input_status=0
cmp -s "$credential_request" "$NATIVE_CREDENTIAL_INPUT" || credential_input_status=$?
assert_eq "local credential helper preserves stdin bytes" "0" "$credential_input_status"
credential_output_status=0
cmp -s "$credential_expected_output" "$credential_actual_output" || credential_output_status=$?
assert_eq "local credential helper preserves stdout bytes" "0" "$credential_output_status"
assert_eq "local credential helper invokes native gh once" "1" "$(grep -c '^auth$' "$NATIVE_ATTEMPT_LOG")"
assert_path_absent "local credential helper emits no API telemetry" "$AIDEVOPS_GH_API_LOG"
credential_failure_status=0
set +e
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" NATIVE_CREDENTIAL_STATUS=17 \
	"$SHIM_FIXTURE/gh" auth git-credential get <"$credential_request" >/dev/null
credential_failure_status=$?
set -e
assert_eq "local credential helper preserves native failure status" "17" "$credential_failure_status"

rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" \
	"$SHIM_FIXTURE/gh" auth git-credential-extra get >/dev/null
assert_file_exists "near-match auth command retains API telemetry" "$AIDEVOPS_GH_API_LOG"
assert_eq "near-match auth command retains one transport attempt" "1" \
	"$(awk -F'\t' '$9 == "attempt" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"

rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?page=2&token=private-value' >/dev/null
assert_eq "shim invokes native gh exactly once" "1" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "shim emits one logical event" "1" "$(awk -F'\t' '$9 == "logical" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "shim emits one transport attempt" "1" "$(awk -F'\t' '$9 == "attempt" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "shim records explicit page number" "2" "$(awk -F'\t' '$9 == "attempt" { print $12 }' "$AIDEVOPS_GH_API_LOG")"
if grep -Eq 'private-owner|private-repo|private-value|token=' "$AIDEVOPS_GH_API_LOG"; then
	echo "  FAIL: shim telemetry exposed path/query arguments"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: shim telemetry keeps path/query arguments private"
	PASS=$((PASS + 1))
fi

# REST pagination is expanded into one observable native command per page while
# preserving one logical operation and framework-owned caller attribution.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	AIDEVOPS_GH_CALLER=gh-api-instrument.sh \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate >/dev/null
"${PARENT_DIR}/gh-api-instrument.sh" report "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1
assert_eq "explicit pagination invokes native gh once per page" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "explicit pagination records page sequence" "1 2" "$(awk -F'\t' '$9 == "attempt" { printf "%s%s", separator, $12; separator=" " } END { print "" }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "explicit pagination uses a framework-owned caller" "2" "$(awk -F'\t' '$9 == "attempt" && $2 == "gh-api-instrument.sh" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "explicit pagination has no opaque attempts" "0" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "explicit pagination supports exactness claims" "true" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"
if grep -q -- '--paginate' "$NATIVE_ATTEMPT_LOG"; then
	echo "  FAIL: native gh retained hidden pagination"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: native gh receives only explicit pages"
	PASS=$((PASS + 1))
fi

# The rollback switch preserves native pagination and its honest opaque marker.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_EXPLICIT_PAGINATION_DISABLE=1 \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate >/dev/null
"${PARENT_DIR}/gh-api-instrument.sh" report "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1
assert_eq "pagination rollback retains native flag" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "pagination rollback remains honestly opaque" "1" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"

# Native gh rejects --slurp combined with --jq or --template before issuing an
# HTTP request. Preserve that CLI validation result without misclassifying the
# native process invocation as an opaque transport attempt.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
preflight_jq_rc=0
preflight_jq_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_REJECT_SLURP_FILTERS=1 \
	"$SHIM_FIXTURE/gh" api --method GET --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' -f state=open \
	--slurp --jq '.' 2>&1) || preflight_jq_rc=$?
preflight_template_rc=0
preflight_template_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_REJECT_SLURP_FILTERS=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --slurp --template '{{.}}' 2>&1) || preflight_template_rc=$?
"${PARENT_DIR}/gh-api-instrument.sh" report "$AIDEVOPS_GH_API_REPORT" >/dev/null 2>&1
assert_eq "slurp/jq native preflight exit is preserved" "1" "$preflight_jq_rc"
assert_eq "slurp/template native preflight exit is preserved" "1" "$preflight_template_rc"
assert_eq "native CLI still validates both invalid invocations" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "invalid pagination combinations retain logical events" "2" "$(awk -F'\t' '$9 == "logical" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"
assert_eq "invalid pagination combinations record zero transport attempts" "0" "$(jq -r '._meta.attempted_requests' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "invalid pagination combinations create no opaque attempts" "0" "$(jq -r '._meta.opaque_paginated_attempts' "$AIDEVOPS_GH_API_REPORT")"
assert_eq "invalid pagination combinations preserve exactness" "true" "$(jq -r '._meta.attempts_exact' "$AIDEVOPS_GH_API_REPORT")"
if [[ "$preflight_jq_output" == *"not supported with --jq or --template"* &&
	"$preflight_template_output" == *"not supported with --jq or --template"* ]]; then
	echo "  PASS: native preflight diagnostics are preserved"
	PASS=$((PASS + 1))
else
	echo "  FAIL: native preflight diagnostics changed"
	FAIL=$((FAIL + 1))
fi

# Streaming jq remains page-local, matching native gh pagination semantics.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
jq_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --paginate '/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "explicit pagination preserves per-page jq output" $'1\n2' "$jq_output"

# Option values that resemble pagination flags remain values rather than being
# consumed as shim controls.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
option_value_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api -H '--slurp' --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "pagination-like option values preserve output" $'1\n2' "$option_value_output"
assert_eq "pagination-like option values reach every page" "2" "$(grep -c -- '^--slurp$' "$NATIVE_ATTEMPT_LOG")"

# Explicit GET fields are query parameters, so their page loop remains
# observable. Fields without an explicit method retain native POST semantics.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
get_field_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --method GET --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' -f since=2026-07-01T00:00:00Z --jq '.[].page')
assert_eq "explicit pagination supports explicit GET query fields" $'1\n2' "$get_field_output"
assert_eq "explicit GET query fields invoke one native command per page" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "explicit GET query fields remove native pagination" "0" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG" || true)"
assert_eq "next-page links do not replay explicit GET fields" "1" "$(grep -c '^since=2026-07-01T00:00:00Z$' "$NATIVE_ATTEMPT_LOG")"

rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	"$SHIM_FIXTURE/gh" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate -f state=open >/dev/null
assert_eq "implicit field method retains native pagination semantics" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"

# Enterprise Link URLs are host-checked and normalized back to gh endpoint
# paths without replaying the /api/v3 prefix.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
enterprise_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_ENTERPRISE_LINK=1 \
	"$SHIM_FIXTURE/gh" api --hostname ghe.example --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "enterprise Link pagination preserves output" $'1\n2' "$enterprise_output"
assert_eq "enterprise Link pagination strips API prefix" "1" "$(grep -c '^repos/fixture/items?per_page=100&page=2$' "$NATIVE_ATTEMPT_LOG")"
assert_eq "enterprise Link pagination avoids duplicated API prefix" "0" "$(grep -c '^api/v3/' "$NATIVE_ATTEMPT_LOG" || true)"

# Commas inside a Link target are data, not page-link separators.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
comma_link_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_COMMA_LINK=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "comma-bearing Link pagination preserves output" $'1\n2' "$comma_link_output"
assert_eq "comma-bearing next endpoint remains intact" "1" "$(grep -c '^repos/fixture/items?labels=bug,help-wanted&page=2$' "$NATIVE_ATTEMPT_LOG")"

# A URL query parameter named rel must not override the Link relation declared
# after the closing angle bracket.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
query_rel_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_QUERY_REL_ONLY=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' --jq '.[].page')
assert_eq "URL query rel does not impersonate the Link relation" "1" "$query_rel_output"
assert_eq "non-next Link relation stops after the first page" "1" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"

# Raw bodies remain byte-for-byte intact, including a missing final newline.
raw_actual="$TMPDIR/raw-pagination.actual"
raw_expected="$TMPDIR/raw-pagination.expected"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG" "$raw_actual" "$raw_expected"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 NATIVE_NO_FINAL_NEWLINE=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >"$raw_actual"
printf '[{"page":1}][{"page":2}]' >"$raw_expected"
if cmp -s "$raw_expected" "$raw_actual"; then
	echo "  PASS: explicit pagination preserves raw response bytes"
	PASS=$((PASS + 1))
else
	echo "  FAIL: explicit pagination changed raw response bytes"
	FAIL=$((FAIL + 1))
fi

# Repeated next links stop before a duplicate request and remove private temp
# responses on the error path.
cycle_temp="$TMPDIR/cycle-temp"
mkdir -p "$cycle_temp"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
if PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_TEMP_DIR="$cycle_temp" NATIVE_PAGINATED_RESPONSE=1 NATIVE_CYCLIC_LINK=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >/dev/null 2>/dev/null; then
	echo "  FAIL: cyclic next link unexpectedly succeeded"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: cyclic next link fails closed"
	PASS=$((PASS + 1))
fi
assert_eq "cyclic next link stops before duplicate request" "2" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"
shopt -s nullglob
cycle_leftovers=("$cycle_temp"/gh-rest-pages.*)
shopt -u nullglob
assert_eq "pagination error removes private temp responses" "0" "${#cycle_leftovers[@]}"

# Pre-transport temp setup failures fall back to native pagination; once the
# first page starts, page-budget failures remain explicit errors.
blocked_temp="$TMPDIR/not-a-directory"
printf 'blocked' >"$blocked_temp"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_TEMP_DIR="$blocked_temp" \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >/dev/null
assert_eq "temp setup failure falls back to native pagination" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"

rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
if PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	AIDEVOPS_GH_REST_MAX_PAGES=1 NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --paginate \
	'/repos/private-owner/private-repo/issues?per_page=100' >/dev/null 2>/dev/null; then
	echo "  FAIL: page-budget exhaustion unexpectedly succeeded"
	FAIL=$((FAIL + 1))
else
	echo "  PASS: page-budget exhaustion fails closed"
	PASS=$((PASS + 1))
fi
assert_eq "page budget prevents an excess request" "1" "$(grep -c '^api$' "$NATIVE_ATTEMPT_LOG")"

# Silent output remains on native pagination because explicit header parsing
# requires response bytes that --silent intentionally suppresses.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	"$SHIM_FIXTURE/gh" api --paginate --silent \
	'/repos/private-owner/private-repo/issues?per_page=100'
assert_eq "silent pagination retains native semantics" "1" "$(grep -c -- '^--paginate$' "$NATIVE_ATTEMPT_LOG")"

# Slurp buffers raw page objects into the same outer-array contract as gh.
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
slurp_output=$(PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	"$SHIM_FIXTURE/gh" api --paginate '/repos/private-owner/private-repo/issues?per_page=100' --slurp | jq -c '.')
assert_eq "explicit pagination preserves slurp output" '[[{"page":1}],[{"page":2}]]' "$slurp_output"

# Parent attribution tolerates shell interpreter flags without scanning
# arbitrary non-interpreter command arguments for coincidental basenames.
cat >"$SHIM_FIXTURE/parent-caller.sh" <<'EOF_PARENT_CALLER'
#!/usr/bin/env bash
"$GH_SHIM_FIXTURE" api '/repos/private-owner/private-repo/issues?per_page=100' --paginate >/dev/null
EOF_PARENT_CALLER
chmod +x "$SHIM_FIXTURE/parent-caller.sh"
rm -f "$AIDEVOPS_GH_API_LOG" "$NATIVE_ATTEMPT_LOG"
PATH="$NATIVE_FIXTURE:/usr/bin:/bin" AIDEVOPS_GH_SHIM_NO_REST_REWRITE=1 \
	NATIVE_PAGINATED_RESPONSE=1 \
	GH_SHIM_FIXTURE="$SHIM_FIXTURE/gh" \
	bash -euo pipefail "$SHIM_FIXTURE/parent-caller.sh"
assert_eq "interpreter flags preserve framework caller attribution" "2" "$(awk -F'\t' '$9 == "attempt" && $2 == "parent-caller.sh" { count++ } END { print count + 0 }' "$AIDEVOPS_GH_API_LOG")"

# --- Test 16: managed scratch cleanup is owner-aware and exact ---------------
scratch_fixture="$TMPDIR/managed-scratch"
mkdir -p "$scratch_fixture"
export AIDEVOPS_GH_API_LOG="$scratch_fixture/gh-api-calls.log"
export AIDEVOPS_GH_API_REPORT="$scratch_fixture/report.json"
export AIDEVOPS_GH_API_EVIDENCE="$scratch_fixture/evidence.json"
export AIDEVOPS_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS=3600
unset _GH_API_INSTRUMENT_LOADED
# shellcheck source=../gh-api-instrument.sh
source "${PARENT_DIR}/gh-api-instrument.sh"

_gh_prepare_scratch_dir "$GH_API_REPORT"
scratch_dir="$scratch_fixture/.gh-api-instrument-scratch"
assert_eq "managed scratch is target-adjacent for atomic rename" "$scratch_dir" "$_GH_API_SCRATCH_DIR"
scratch_mode=$(file_mode "$scratch_dir")
assert_eq "managed scratch directory is private" "700" "$scratch_mode"

dead_pid=999999999
while kill -0 "$dead_pid" 2>/dev/null; do
	dead_pid=$((dead_pid - 1))
done
live_pid="${BASHPID:-$$}"
dead_report="$scratch_dir/report.${dead_pid}.ABC123"
dead_source="$scratch_dir/source.${dead_pid}.DEF456"
dead_trim="$scratch_dir/trim.${dead_pid}.GHI789"
live_source="$scratch_dir/source.${live_pid}.LIV123"
invalid_suffix="$scratch_dir/report.${dead_pid}.ABC12_"
unrelated_file="$scratch_dir/unrelated.${dead_pid}.ABC123"
symlink_target="$scratch_fixture/symlink-target"
scratch_symlink="$scratch_dir/source.${dead_pid}.SYM123"
printf 'dead report\n' >"$dead_report"
printf 'dead source\n' >"$dead_source"
printf 'dead trim\n' >"$dead_trim"
printf 'live source\n' >"$live_source"
printf 'invalid suffix\n' >"$invalid_suffix"
printf 'unrelated\n' >"$unrelated_file"
printf 'target\n' >"$symlink_target"
ln -s "$symlink_target" "$scratch_symlink"

assert_eq "managed scratch parser returns creator PID" "$dead_pid" "$(_gh_managed_scratch_owner_pid "report.${dead_pid}.ABC123")"
invalid_owner_status=0
_gh_managed_scratch_owner_pid "report.${dead_pid}.ABC12_" >/dev/null || invalid_owner_status=$?
assert_eq "managed scratch parser rejects non-exact suffixes" "1" "$invalid_owner_status"
_gh_cleanup_managed_scratch "$scratch_dir"
assert_path_absent "dead-owner report scratch is reaped" "$dead_report"
assert_path_absent "dead-owner source scratch is reaped" "$dead_source"
assert_path_absent "dead-owner trim scratch is reaped" "$dead_trim"
assert_file_exists "live-owner scratch is preserved" "$live_source"
assert_file_exists "non-exact managed filename is preserved" "$invalid_suffix"
assert_file_exists "unrelated managed-directory file is preserved" "$unrelated_file"
assert_eq "managed scratch symlink is preserved" "yes" "$([[ -L "$scratch_symlink" ]] && printf 'yes' || printf 'no')"
assert_file_exists "managed scratch symlink target is untouched" "$symlink_target"

# SIGKILL aggregate fixture: replace cp in the child only. The wrapper copies
# the snapshot, then kills its parent before normal report/source cleanup.
kill_bin="$scratch_fixture/kill-bin"
aggregate_marker="$scratch_fixture/aggregate-killed.marker"
aggregate_owner_pid_file="$scratch_fixture/aggregate-owner.pid"
mkdir -p "$kill_bin"
cat >"$kill_bin/cp" <<'EOF_KILL_CP'
#!/usr/bin/env bash
set -euo pipefail
/bin/cp "$@"
printf 'ready\n' >"$GH_API_KILL_MARKER"
kill -KILL "$PPID"
exit 137
EOF_KILL_CP
chmod +x "$kill_bin/cp"
cat >"$kill_bin/run-sigkill-fixture" <<'EOF_SIGKILL_RUNNER'
#!/usr/bin/env bash
set +e
bash -c '
	printf "%s\n" "${BASHPID:-$$}" >"$GH_API_OWNER_PID_FILE"
	unset _GH_API_INSTRUMENT_LOADED
	source "$1"
	case "$2" in
	aggregate) gh_aggregate_calls "$GH_API_REPORT_PATH" ;;
	trim) gh_trim_log ;;
	*) exit 2 ;;
	esac
' _ "$GH_API_INSTRUMENT_SCRIPT" "$GH_API_KILL_MODE"
fixture_status=$?
exit "$fixture_status"
EOF_SIGKILL_RUNNER
chmod +x "$kill_bin/run-sigkill-fixture"
gh_clear_log
gh_record_call rest scratch-sigkill-aggregate
set +e
PATH="$kill_bin:$PATH" GH_API_KILL_MARKER="$aggregate_marker" \
	AIDEVOPS_GH_API_LOG="$GH_API_LOG" AIDEVOPS_GH_API_REPORT="$GH_API_REPORT" \
	GH_API_OWNER_PID_FILE="$aggregate_owner_pid_file" GH_API_KILL_MODE=aggregate \
	GH_API_INSTRUMENT_SCRIPT="${PARENT_DIR}/gh-api-instrument.sh" GH_API_REPORT_PATH="$GH_API_REPORT" \
	"$kill_bin/run-sigkill-fixture" >/dev/null 2>&1
aggregate_kill_status=$?
set -e
aggregate_kill_pid=$(<"$aggregate_owner_pid_file")
assert_eq "aggregate SIGKILL fixture reached snapshot copy" "yes" "$([[ -f "$aggregate_marker" ]] && printf 'yes' || printf 'no')"
assert_eq "aggregate fixture exits from SIGKILL" "137" "$aggregate_kill_status"
shopt -s nullglob
aggregate_orphans=(
	"$scratch_dir/report.${aggregate_kill_pid}."*
	"$scratch_dir/source.${aggregate_kill_pid}."*
)
shopt -u nullglob
assert_eq "aggregate SIGKILL leaves owner-tagged report and source scratch" "2" "${#aggregate_orphans[@]}"
for aggregate_orphan in "${aggregate_orphans[@]}"; do
	aggregate_orphan_mode=$(file_mode "$aggregate_orphan")
	assert_eq "aggregate scratch remains private after SIGKILL" "600" "$aggregate_orphan_mode"
done
_gh_cleanup_managed_scratch "$scratch_dir"
shopt -s nullglob
aggregate_orphans=(
	"$scratch_dir/report.${aggregate_kill_pid}."*
	"$scratch_dir/source.${aggregate_kill_pid}."*
)
shopt -u nullglob
assert_eq "next cleanup reaps aggregate SIGKILL scratch" "0" "${#aggregate_orphans[@]}"
gh_record_call rest scratch-post-aggregate-recovery
assert_eq "aggregate SIGKILL lock is recoverable" "2" "$(wc -l <"$GH_API_LOG" | tr -d ' ')"

# SIGKILL trim fixture: replace awk in the child so the process dies after its
# owner-tagged trim file and lock exist but before atomic replacement.
trim_marker="$scratch_fixture/trim-killed.marker"
trim_owner_pid_file="$scratch_fixture/trim-owner.pid"
cat >"$kill_bin/awk" <<'EOF_KILL_AWK'
#!/usr/bin/env bash
set -euo pipefail
printf 'ready\n' >"$GH_API_KILL_MARKER"
kill -KILL "$PPID"
exit 137
EOF_KILL_AWK
chmod +x "$kill_bin/awk"
set +e
PATH="$kill_bin:$PATH" GH_API_KILL_MARKER="$trim_marker" \
	AIDEVOPS_GH_API_LOG="$GH_API_LOG" AIDEVOPS_GH_API_REPORT="$GH_API_REPORT" \
	GH_API_OWNER_PID_FILE="$trim_owner_pid_file" GH_API_KILL_MODE=trim \
	GH_API_INSTRUMENT_SCRIPT="${PARENT_DIR}/gh-api-instrument.sh" GH_API_REPORT_PATH="$GH_API_REPORT" \
	"$kill_bin/run-sigkill-fixture" >/dev/null 2>&1
trim_kill_status=$?
set -e
trim_kill_pid=$(<"$trim_owner_pid_file")
assert_eq "trim SIGKILL fixture reached retention filter" "yes" "$([[ -f "$trim_marker" ]] && printf 'yes' || printf 'no')"
assert_eq "trim fixture exits from SIGKILL" "137" "$trim_kill_status"
shopt -s nullglob
trim_orphans=("$scratch_dir/trim.${trim_kill_pid}."*)
shopt -u nullglob
assert_eq "trim SIGKILL leaves one owner-tagged scratch file" "1" "${#trim_orphans[@]}"
trim_orphan_mode=$(file_mode "${trim_orphans[0]}")
assert_eq "trim scratch remains private after SIGKILL" "600" "$trim_orphan_mode"
_gh_cleanup_managed_scratch "$scratch_dir"
shopt -s nullglob
trim_orphans=("$scratch_dir/trim.${trim_kill_pid}."*)
shopt -u nullglob
assert_eq "next cleanup reaps trim SIGKILL scratch" "0" "${#trim_orphans[@]}"
gh_trim_log
assert_eq "trim SIGKILL lock is recoverable" "no" "$([[ -d "${GH_API_LOG}.lock" ]] && printf 'yes' || printf 'no')"
trimmed_log_mode=$(file_mode "$GH_API_LOG")
assert_eq "trim replacement keeps the durable log private" "600" "$trimmed_log_mode"

# Legacy migration is age-gated and accepts only the exact historical six-
# character mktemp suffixes. Symlinks, recent files, and near-matches survive.
legacy_source="${GH_API_REPORT}.source.LEG123"
legacy_report="${GH_API_REPORT}.tmp.LEG456"
legacy_trim="${GH_API_LOG}.trim.LEG789"
legacy_recent="${GH_API_REPORT}.source.NEW123"
legacy_near_match="${GH_API_REPORT}.source.TOOLONG"
legacy_symlink_target="$scratch_fixture/legacy-symlink-target"
legacy_symlink="${GH_API_LOG}.trim.SYM123"
printf 'legacy source\n' >"$legacy_source"
printf 'legacy report\n' >"$legacy_report"
printf 'legacy trim\n' >"$legacy_trim"
printf 'recent\n' >"$legacy_recent"
printf 'near match\n' >"$legacy_near_match"
printf 'target\n' >"$legacy_symlink_target"
ln -s "$legacy_symlink_target" "$legacy_symlink"
python3 - "$legacy_source" "$legacy_report" "$legacy_trim" "$legacy_near_match" <<'PY_LEGACY_MTIME'
import os
import sys
import time

old = time.time() - 7200
for path in sys.argv[1:]:
    os.utime(path, (old, old))
PY_LEGACY_MTIME
_gh_cleanup_legacy_scratch
assert_path_absent "old exact legacy source scratch is removed" "$legacy_source"
assert_path_absent "old exact legacy report scratch is removed" "$legacy_report"
assert_path_absent "old exact legacy trim scratch is removed" "$legacy_trim"
assert_file_exists "recent exact legacy scratch is preserved" "$legacy_recent"
assert_file_exists "old near-match legacy file is preserved" "$legacy_near_match"
assert_eq "legacy scratch symlink is preserved" "yes" "$([[ -L "$legacy_symlink" ]] && printf 'yes' || printf 'no')"
assert_file_exists "legacy scratch symlink target is untouched" "$legacy_symlink_target"
invalid_legacy_age=$(AIDEVOPS_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS=invalid bash -c '
	# shellcheck source=/dev/null
	source "$1"
	printf "%s\n" "$_GH_API_LEGACY_SCRATCH_MIN_AGE_SECONDS"
' _ "${PARENT_DIR}/gh-api-instrument.sh")
assert_eq "invalid legacy scratch age uses the safe default" "3600" "$invalid_legacy_age"

# A pre-created symlink cannot redirect the managed scratch directory.
bad_scratch_parent="$TMPDIR/bad-scratch-parent"
bad_scratch_target="$TMPDIR/bad-scratch-target"
mkdir -p "$bad_scratch_parent" "$bad_scratch_target"
ln -s "$bad_scratch_target" "$bad_scratch_parent/.gh-api-instrument-scratch"
bad_scratch_status=0
_gh_prepare_scratch_dir "$bad_scratch_parent/report.json" || bad_scratch_status=$?
assert_eq "managed scratch rejects a pre-created directory symlink" "1" "$bad_scratch_status"
assert_eq "rejected scratch symlink target stays empty" "0" "$(ls -A "$bad_scratch_target" | wc -l | tr -d ' ')"

# --- Summary ----------------------------------------------------------
echo ""
echo "===================================================="
echo "Result: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
