#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn

set -uo pipefail

TESTS_RUN=0
TESTS_FAILED=0
TMP=$(mktemp -d -t pulse-cycle-gates.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

pass() {
	local name="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf 'PASS %s\n' "$name"
	return 0
}

fail() {
	local name="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf 'FAIL %s %s\n' "$name" "$detail"
	return 0
}

export SCRIPT_DIR="${TMP}/scripts"
export WRAPPER_LOGFILE="${TMP}/wrapper.log"
export AIDEVOPS_GH_API_EVIDENCE_COVERAGE_START_FILE="${TMP}/coverage-start"
export PULSE_SCOPE_REPOS="owner/repo"
unset GH_API_REPORT
mkdir -p "$SCRIPT_DIR"
: >"$WRAPPER_LOGFILE"

GH_QUERY_FILE="${TMP}/query.txt"
TIMEOUT_CALL_FILE="${TMP}/timeout.txt"
export GH_QUERY_FILE
export TIMEOUT_CALL_FILE
export TIMEOUT_MODE="pass"
gh() {
	printf '%s\n' "$*" >"$GH_QUERY_FILE"
	printf '0\n'
	return 0
}

timeout_sec() {
	local timeout_seconds="$1"
	shift
	printf '%s\n' "$timeout_seconds" >"$TIMEOUT_CALL_FILE"
	if [[ "$TIMEOUT_MODE" == "timeout" ]]; then
		return 124
	fi
	"$@"
	return $?
}

cat >"${SCRIPT_DIR}/pulse-idle-backoff-helper.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
should-skip) exit 0 ;;
state)
	printf '{"consecutive_idle":2,"current_effective_interval_s":120}\n'
	exit 0
	;;
*) exit 1 ;;
esac
EOF
chmod +x "${SCRIPT_DIR}/pulse-idle-backoff-helper.sh"

EVIDENCE_FILE="${TMP}/evidence.log"
EVIDENCE_TIMESTAMP_FILE="${TMP}/evidence-timestamps.log"
AGGREGATE_FILE="${TMP}/aggregate.log"
TRIM_FILE="${TMP}/trim.log"
: >"$EVIDENCE_FILE"
: >"$EVIDENCE_TIMESTAMP_FILE"
: >"$AGGREGATE_FILE"
: >"$TRIM_FILE"

gh_record_efficiency_evidence() {
	local name="$1"
	local value="$2"
	local recorded_at="${3:-${EVIDENCE_APPEND_NOW:-}}"
	printf '%s=%s\n' "$name" "$value" >>"$EVIDENCE_FILE"
	printf '%s=%s\n' "$name" "$recorded_at" >>"$EVIDENCE_TIMESTAMP_FILE"
	return 0
}

gh_aggregate_calls() {
	printf "%s|%s|%s\n" "${1:-}" "${2:-}" "${3:-}" >>"$AGGREGATE_FILE"
	return 0
}

gh_trim_log() {
	printf 'trim\n' >>"$TRIM_FILE"
	return 0
}

SOURCE_SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pulse-wrapper-cycle-gates.sh"
# shellcheck disable=SC1090
source "$SOURCE_SCRIPT"

if _pulse_available_auto_dispatch_work_exists; then
	fail "zero eligible issues does not bypass idle backoff"
else
	pass "zero eligible issues does not bypass idle backoff"
fi

if grep -q -- '-label:needs-maintainer-review' "$GH_QUERY_FILE"; then
	pass "idle-work query excludes NMR-held issues"
else
	fail "idle-work query excludes NMR-held issues" "query=$(<"$GH_QUERY_FILE")"
fi

if grep -q -- '-label:infrastructure' "$GH_QUERY_FILE"; then
	pass "idle-work query excludes infrastructure advisory issues"
else
	fail "idle-work query excludes infrastructure advisory issues" "query=$(<"$GH_QUERY_FILE")"
fi

if grep -q -- '-label:publication:pending' "$GH_QUERY_FILE"; then
	pass "idle-work query excludes unpublished planning issues"
else
	fail "idle-work query excludes unpublished planning issues" "query=$(<"$GH_QUERY_FILE")"
fi

timeout_value=$(<"$TIMEOUT_CALL_FILE")
if grep -q 'AIDEVOPS_PULSE_IDLE_AVAILABLE_WORK_TIMEOUT:-30' "$SOURCE_SCRIPT" &&
	[[ "$timeout_value" =~ ^[0-9]+$ ]] &&
	[[ "$timeout_value" -ge 1 && "$timeout_value" -le 30 ]]; then
	pass "idle-work query uses bounded default timeout"
else
	fail "idle-work query uses bounded default timeout" "timeout=$timeout_value"
fi

export TIMEOUT_MODE="timeout"
if _pulse_available_auto_dispatch_work_exists; then
	fail "idle-work query surfaces timeout status"
else
	query_rc=$?
	if [[ "$query_rc" -eq 124 ]]; then
		pass "idle-work query surfaces timeout status"
	else
		fail "idle-work query surfaces timeout status" "rc=${query_rc}"
	fi
fi

if _pulse_check_idle_backoff_gate; then
	pass "idle-work timeout bypasses idle backoff"
else
	fail "idle-work timeout bypasses idle backoff"
fi

if grep -q 'timed out after 30s' "$WRAPPER_LOGFILE"; then
	pass "idle-work timeout is logged"
else
	fail "idle-work timeout is logged"
fi

: >"$EVIDENCE_FILE"
: >"$EVIDENCE_TIMESTAMP_FILE"
: >"$AGGREGATE_FILE"
: >"$TRIM_FILE"
_pulse_efficiency_cycle_start
efficiency_cycle_id="${AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID:-}"
_PULSE_EFFICIENCY_CYCLE_START_MS=$((_PULSE_EFFICIENCY_CYCLE_START_MS - 25))
_pulse_efficiency_cycle_finish idle
if grep -q '^contract=2$' "$EVIDENCE_FILE" &&
	grep -q '^coverage-start=[0-9]' "$EVIDENCE_FILE" &&
	grep -q '^coverage.population=2$' "$EVIDENCE_FILE" &&
	grep -q '^coverage.latency=2$' "$EVIDENCE_FILE" &&
	grep -q '^coverage.cache=2$' "$EVIDENCE_FILE" &&
	grep -q '^coverage.single_flight=2$' "$EVIDENCE_FILE" &&
	grep -q '^coverage.webhook=2$' "$EVIDENCE_FILE" &&
	grep -q '^coverage.guardrails=2$' "$EVIDENCE_FILE" &&
	grep -q '^coverage.path_budgets=2$' "$EVIDENCE_FILE" &&
	grep -q '^population.pulse_cycles=1$' "$EVIDENCE_FILE" &&
	grep -q '^population.unchanged_cycles=1$' "$EVIDENCE_FILE" &&
	grep -q '^coverage-end=[0-9]' "$EVIDENCE_FILE" &&
	[[ "$efficiency_cycle_id" =~ ^[0-9]+$ ]] &&
	[[ -z "${AIDEVOPS_GH_API_EFFICIENCY_CYCLE_ID:-}" ]] &&
	! grep -q '^latency.completed_action_ms=' "$EVIDENCE_FILE"; then
	pass "idle cycle publishes complete typed evidence"
else
	fail "idle cycle publishes complete typed evidence"
fi

coverage_end_value=$(grep "^coverage-end=" "$EVIDENCE_FILE")
coverage_end_value="${coverage_end_value#*=}"
if grep -q -- "^|86400|${coverage_end_value}$" "$AGGREGATE_FILE"; then
	pass "cycle aggregate uses the completed coverage cutoff"
else
	fail "cycle aggregate uses the completed coverage cutoff" "args=$(<"$AGGREGATE_FILE")"
fi

# Simulate the recorder entering the next second after cycle finish captured its
# cutoff. The explicit record timestamp must stay aligned with the marker value
# and aggregate cutoff instead of widening the completed window (GH#28493).
: >"$EVIDENCE_FILE"
: >"$EVIDENCE_TIMESTAMP_FILE"
: >"$AGGREGATE_FILE"
: >"$TRIM_FILE"
EVIDENCE_APPEND_NOW=2001
_pulse_efficiency_now_seconds() {
	printf '2000\n'
	return 0
}
_pulse_efficiency_cycle_start
_pulse_efficiency_cycle_finish idle
rollover_marker=$(grep '^coverage-end=' "$EVIDENCE_FILE")
rollover_record_ts=$(grep '^coverage-end=' "$EVIDENCE_TIMESTAMP_FILE")
rollover_aggregate=$(<"$AGGREGATE_FILE")
if [[ "$rollover_marker" == "coverage-end=2000" &&
	"$rollover_record_ts" == "coverage-end=2000" &&
	"$rollover_aggregate" == "|86400|2000" ]]; then
	pass "second rollover keeps coverage marker inside completed cutoff"
else
	fail "second rollover keeps coverage marker inside completed cutoff" \
		"marker=${rollover_marker} record=${rollover_record_ts} aggregate=${rollover_aggregate} append_now=${EVIDENCE_APPEND_NOW}"
fi
unset EVIDENCE_APPEND_NOW
_pulse_efficiency_now_seconds() {
	date +%s 2>/dev/null || printf '0\n'
	return 0
}

_pulse_efficiency_cycle_finish idle
if [[ "$(wc -l <"$AGGREGATE_FILE" | tr -d ' ')" == "1" ]] &&
	[[ "$(wc -l <"$TRIM_FILE" | tr -d ' ')" == "1" ]]; then
	pass "cycle finish aggregates and trims exactly once"
else
	fail "cycle finish aggregates and trims exactly once"
fi

: >"$EVIDENCE_FILE"
_PULSE_HEALTH_PRS_MERGED=1
_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=0
_PULSE_EFFICIENCY_CYCLE_OUTCOME=idle
_pulse_efficiency_cycle_start
_PULSE_EFFICIENCY_CYCLE_START_MS=$((_PULSE_EFFICIENCY_CYCLE_START_MS - 25))
_pulse_record_cycle_outcome 0
_pulse_efficiency_cycle_finish
if [[ "$_PULSE_EFFICIENCY_CYCLE_OUTCOME" == "active" ]] &&
	grep -Eq '^latency.completed_action_ms=[1-9][0-9]*$' "$EVIDENCE_FILE" &&
	! grep -q '^population.unchanged_cycles=' "$EVIDENCE_FILE"; then
	pass "active cycle records completed-action latency"
else
	fail "active cycle records completed-action latency"
fi

FINAL_TYPED_OUTCOME=""
FINAL_PROGRESS_KINDS="[]"
_pulse_cycle_state_finalize() {
	local outcome="$1"
	local progress_kinds="$2"
	FINAL_TYPED_OUTCOME="$outcome"
	FINAL_PROGRESS_KINDS="$progress_kinds"
	return 0
}

export AIDEVOPS_DISPATCH_LEDGER_FILE="${TMP}/dispatch-ledger.jsonl"
printf '%s\n' \
	'{"lease_phase":"prelaunch","dispatched_at":"2026-01-01T00:00:00Z"}' \
	'{malformed' \
	'{"lease_phase":"ready","dispatched_at":"2026-01-01T00:00:01Z"}' \
	'{"lease_phase":"prelaunch","dispatched_at":"2026-01-01T00:00:02Z"}' \
	>"$AIDEVOPS_DISPATCH_LEDGER_FILE"
if [[ "$(_pulse_capture_dispatch_total)" == "2" ]]; then
	pass "dispatch total counts successful registrations and ignores malformed rows"
else
	fail "dispatch total counts successful registrations and ignores malformed rows"
fi

_PULSE_HEALTH_PRS_MERGED=0
_PULSE_HEALTH_PRS_CLOSED_CONFLICTING=0
_PULSE_CYCLE_BLOCKER_KIND="none"
_PULSE_EFFICIENCY_CYCLE_OUTCOME="idle"
_pulse_record_cycle_outcome 1
if [[ "$FINAL_TYPED_OUTCOME" == "progressed" &&
	"$_PULSE_EFFICIENCY_CYCLE_OUTCOME" == "active" ]] &&
	printf '%s' "$FINAL_PROGRESS_KINDS" | jq -e '. == ["worker-dispatched"]' >/dev/null; then
	pass "worker registration maps to typed progress and legacy active"
else
	fail "worker registration maps to typed progress and legacy active"
fi

_PULSE_CYCLE_BLOCKER_KIND="review-gate"
_pulse_record_cycle_outcome 2
if [[ "$FINAL_TYPED_OUTCOME" == "blocked" &&
	"$_PULSE_EFFICIENCY_CYCLE_OUTCOME" == "idle" &&
	"$FINAL_PROGRESS_KINDS" == "[]" ]]; then
	pass "typed blocker maps to blocked and legacy idle"
else
	fail "typed blocker maps to blocked and legacy idle"
fi

_PULSE_CYCLE_BLOCKER_KIND="none"
_pulse_record_cycle_outcome 2
if [[ "$FINAL_TYPED_OUTCOME" == "idle" &&
	"$_PULSE_EFFICIENCY_CYCLE_OUTCOME" == "idle" &&
	"$FINAL_PROGRESS_KINDS" == "[]" ]]; then
	pass "no durable evidence maps to typed and legacy idle"
else
	fail "no durable evidence maps to typed and legacy idle"
fi

PREFETCH_INFRA="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pulse-prefetch-infra.sh"
# shellcheck disable=SC1090
source "$PREFETCH_INFRA"
local_entries_a=$'beta/repo|/private/beta\nalpha/repo|/private/alpha\nbeta/repo|/duplicate'
local_entries_b=$'alpha/repo|/changed/path\nbeta/repo|/other/path'
: >"$EVIDENCE_FILE"
_prefetch_record_efficiency_population "$local_entries_a"
repo_hash_a=$(awk -F= '$1 == "population.repository_set_sha256" {print $2}' "$EVIDENCE_FILE")
first_population_log=$(<"$EVIDENCE_FILE")
: >"$EVIDENCE_FILE"
_prefetch_record_efficiency_population "$local_entries_b"
repo_hash_b=$(awk -F= '$1 == "population.repository_set_sha256" {print $2}' "$EVIDENCE_FILE")
if [[ "$repo_hash_a" =~ ^[0-9a-f]{64}$ && "$repo_hash_a" == "$repo_hash_b" ]] &&
	printf '%s\n' "$first_population_log" | grep -q '^population.repository_count=2$' &&
	! printf '%s\n' "$first_population_log" | grep -qE 'alpha/repo|beta/repo|/private/'; then
	pass "repository population evidence is deterministic and private"
else
	fail "repository population evidence is deterministic and private"
fi

PREFETCH_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pulse-prefetch-repo.sh"
# shellcheck disable=SC1090
source "$PREFETCH_REPO"
: >"$EVIDENCE_FILE"
PULSE_BATCH_PREFETCH_ENABLED=0
_prefetch_single_repo_load_snapshots alpha/repo
if [[ "$(grep -c '^cache.misses=1$' "$EVIDENCE_FILE")" == "2" ]] &&
	[[ "$(grep -c '^guardrails.forced_live_refreshes=1$' "$EVIDENCE_FILE")" == "2" ]]; then
	pass "disabled canonical cache records forced live decisions"
else
	fail "disabled canonical cache records forced live decisions"
fi

SOURCE_CYCLE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/pulse-wrapper-cycle.sh"
if grep -q 'Do not run Bash tool calls with workdir set to managed repository paths' "$SOURCE_CYCLE" &&
	grep -q 'external_directory permission' "$SOURCE_CYCLE" &&
	grep -q '_pulse_supervisor_prompt' "$SOURCE_CYCLE"; then
	pass "supervisor prompt prevents external-workdir permission stalls"
else
	fail "supervisor prompt prevents external-workdir permission stalls"
fi

printf '\nTests run: %s failed: %s\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]] || exit 1
exit 0
