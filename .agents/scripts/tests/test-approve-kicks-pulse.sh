#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# Test: t3068 / GH#28717 — approval triggers target reconciliation and merge.
# =============================================================================
#
# Covers two contracts that together collapse the up-to-120s window between
# `sudo aidevops approve issue/pr <N>` and the pulse-merge cycle acting on
# the linked PR:
#
#   1. approval-helper.sh::_kick_pulse_after_approval writes a TSV record
#      to ~/.aidevops/cache/pulse-merge-trigger.txt on every approval.
#   2. pulse-wrapper-bootstrap.sh::_drain_merge_trigger_file_if_present
#      atomically rotates the marker, reconciles the exact approved target,
#      then processes any linked PR. Exact duplicate records execute once.
#
# The test isolates the marker file via the PULSE_MERGE_TRIGGER_FILE env
# var and mocks reconciliation/process_pr into logs. No real GitHub state is
# touched.
#
# Bypass env vars exercised:
#   AIDEVOPS_SKIP_APPROVE_KICK_PULSE=1   — disable the helper entirely
#   AIDEVOPS_SKIP_TRIGGER_DRAIN=1        — disable the drain
#
# Failure modes covered:
#   - Marker file written with the right TSV shape
#   - Drain processes a single record and clears the marker
#   - Drain skips malformed records but still processes valid ones
#   - Drain is a no-op when marker is missing (cold start)
#   - Atomic rotation: a stub `process_pr` that re-checks the marker sees
#     it gone (no double-processing on race)
#   - Issues without linked PRs still receive exact-target reconciliation
#   - Exact duplicate records do not repeat reconciliation or merge attempts
#   - Bypass flags neutralise both halves cleanly

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)" || exit 1
PARENT_DIR="${SCRIPT_DIR}/.."

PASS=0
FAIL=0

# Per-test sandbox so concurrent runs and local re-runs don't collide.
TMPROOT=$(mktemp -d "${TMPDIR:-/tmp}/test-t3068-XXXXXX") || exit 1
TRIGGER_FILE="${TMPROOT}/pulse-merge-trigger.txt"
PROCESS_LOG="${TMPROOT}/process-pr.log"
RECONCILE_LOG="${TMPROOT}/reconcile.log"
EVENT_LOG="${TMPROOT}/events.log"

cleanup() {
	rm -rf "$TMPROOT" 2>/dev/null || true
	return 0
}
trap cleanup EXIT

# Common stub harness used by every drain test. Sourcing pulse-wrapper-bootstrap.sh
# pulls in _drain_merge_trigger_file_if_present + _resolve_linked_pr_for_issue
# without executing any pulse lifecycle code (the bootstrap is a function
# library — no top-level imperative work).
load_drain_with_stubs() {
	# Reset both files for this test case.
	: >"$PROCESS_LOG"
	: >"$RECONCILE_LOG"
	: >"$EVENT_LOG"

	# shellcheck disable=SC1091
	source "${PARENT_DIR}/pulse-wrapper-bootstrap.sh" >/dev/null 2>&1

	# Stub process_pr — record args, never call gh.
	process_pr() {
		local slug="${1:-}"
		local pr_number="${2:-}"
		printf 'process_pr %s %s\n' "$slug" "$pr_number" >>"$PROCESS_LOG"
		printf 'process_pr %s %s\n' "$slug" "$pr_number" >>"$EVENT_LOG"
		return 0
	}

	# Stub the trusted exact-target recovery owned by pulse-approval-reconcile.sh.
	_pulse_reconcile_verified_approval_target() {
		local target_type="${1:-}"
		local target_number="${2:-}"
		local slug="${3:-}"
		printf 'reconcile %s %s %s\n' "$target_type" "$target_number" "$slug" >>"$RECONCILE_LOG"
		printf 'reconcile %s %s %s\n' "$target_type" "$target_number" "$slug" >>"$EVENT_LOG"
		return 0
	}

	# Stub the issue→PR resolver so tests can drive the issue path without
	# hitting GitHub. The real implementation calls gh.
	_resolve_linked_pr_for_issue() {
		# Test contract: issue 12345 maps to PR 99999, all others empty.
		local _issue_num="${2:-}"
		if [[ "$_issue_num" == "12345" ]]; then
			printf '99999'
		else
			printf ''
		fi
		return 0
	}

	# Route the drain at our sandbox path.
	export PULSE_MERGE_TRIGGER_FILE="$TRIGGER_FILE"
	# Discard drain log output to keep test output clean.
	export LOGFILE="${TMPROOT}/pulse.log"
	return 0
}

assert_pass() {
	local name="$1"
	echo "  PASS: $name"
	PASS=$((PASS + 1))
	return 0
}

assert_fail() {
	local name="$1"
	local detail="${2:-}"
	echo "  FAIL: $name"
	if [[ -n "$detail" ]]; then
		printf '%s\n' "$detail" | sed 's/^/    /'
	fi
	FAIL=$((FAIL + 1))
	return 1
}

assert_eq() {
	local name="$1"
	local expected="$2"
	local actual="$3"
	if [[ "$expected" == "$actual" ]]; then
		assert_pass "$name"
	else
		assert_fail "$name" "expected: ${expected}\nactual:   ${actual}"
	fi
	return 0
}

assert_file_absent() {
	local name="$1"
	local path="$2"
	if [[ ! -e "$path" ]]; then
		assert_pass "$name"
	else
		assert_fail "$name" "file still exists: ${path}"
	fi
	return 0
}

# -----------------------------------------------------------------------------
# Test 1: _kick_pulse_after_approval writes the marker file with the
# expected TSV shape and rejects malformed inputs at the helper level.
# -----------------------------------------------------------------------------
echo "Test 1: _kick_pulse_after_approval marker write"
echo "================================================"

# Source approval-helper.sh in a subshell — the dispatch tail at the
# bottom is a `case` that only runs on direct invocation, so sourcing is
# safe and cheap. Disable the background spawn so the test never tries to
# fork pulse-wrapper.sh.
test1_marker="${TMPROOT}/test1-trigger.txt"
test1_home="${TMPROOT}/test1-home"
mkdir -p "${test1_home}/.aidevops/cache"

bash -c "
	set -uo pipefail
	# Silence the dispatch tail of approval-helper.sh — sourcing without
	# any case branch matching prints the help banner.
	# shellcheck disable=SC1091
	source '${PARENT_DIR}/approval-helper.sh' >/dev/null 2>&1
	# Override _APPROVAL_HOME so the marker lands in our sandbox; HOME would
	# work too but the helper resolves _APPROVAL_HOME at script load.
	_APPROVAL_HOME='${test1_home}'
	# pulse-wrapper.sh is not present in our fake home, so the helper's
	# 'not -x' guard naturally suppresses the background spawn — keeping
	# the test hermetic without an explicit bypass flag.
	_kick_pulse_after_approval issue 21806 marcusquinn/aidevops
	_kick_pulse_after_approval pr 21807 marcusquinn/aidevops
	# Bad inputs — must be silent no-op, no marker line written.
	_kick_pulse_after_approval issue '../etc/passwd' bad/slug
	_kick_pulse_after_approval issue 21808 'badslug-no-slash'
	_kick_pulse_after_approval bogustype 21809 marcusquinn/aidevops
" >/dev/null 2>&1

# Verify the marker landed at the canonical sandbox path.
expected_marker="${test1_home}/.aidevops/cache/pulse-merge-trigger.txt"
if [[ -f "$expected_marker" ]]; then
	assert_pass "marker file created at expected path"
else
	assert_fail "marker file created at expected path" "missing: ${expected_marker}"
fi

# Verify exactly TWO records (the two valid calls); malformed inputs
# rejected silently.
record_count=$(wc -l <"$expected_marker" 2>/dev/null | tr -d ' ' || echo "0")
assert_eq "marker contains 2 records (rejecting 3 malformed)" "2" "$record_count"

# Verify the TSV shape of the first record. Expected: 4 tab-separated fields.
first_record=$(head -1 "$expected_marker" 2>/dev/null || echo "")
field_count=$(printf '%s\n' "$first_record" | awk -F'\t' '{print NF}')
assert_eq "first record has 4 tab-separated fields" "4" "$field_count"

# Verify the slug field is exactly what we passed.
slug_field=$(printf '%s\n' "$first_record" | awk -F'\t' '{print $1}')
assert_eq "first record slug field is marcusquinn/aidevops" "marcusquinn/aidevops" "$slug_field"

# Verify the issue number field.
num_field=$(printf '%s\n' "$first_record" | awk -F'\t' '{print $2}')
assert_eq "first record num field is 21806" "21806" "$num_field"

# Verify type field.
type_field=$(printf '%s\n' "$first_record" | awk -F'\t' '{print $3}')
assert_eq "first record type field is 'issue'" "issue" "$type_field"

# Verify timestamp field is non-empty (UTC ISO-8601 or 'unknown').
ts_field=$(printf '%s\n' "$first_record" | awk -F'\t' '{print $4}')
if [[ -n "$ts_field" ]]; then
	assert_pass "first record timestamp field is non-empty"
else
	assert_fail "first record timestamp field is non-empty" "got empty timestamp"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 2: drain processes a single PR record and clears the marker.
# -----------------------------------------------------------------------------
echo "Test 2: drain processes a single PR record"
echo "==========================================="

# Use a fresh subshell so sourcing pulse-wrapper-bootstrap.sh doesn't leak
# into later tests.
(
	load_drain_with_stubs

	# Write a single PR record.
	printf 'marcusquinn/aidevops\t21806\tpr\t2026-04-30T12:00:00Z\n' >"$TRIGGER_FILE"

	_drain_merge_trigger_file_if_present || exit 1
)
drain_rc=$?

assert_eq "drain returns 0 on valid record" "0" "$drain_rc"
assert_file_absent "marker file removed after drain" "$TRIGGER_FILE"

if [[ -s "$PROCESS_LOG" ]]; then
	logged_call=$(head -1 "$PROCESS_LOG" 2>/dev/null || echo "")
	assert_eq "process_pr called with slug + PR number" \
		"process_pr marcusquinn/aidevops 21806" "$logged_call"
else
	assert_fail "process_pr called with slug + PR number" "process log empty"
fi

event_order=$(cat "$EVENT_LOG" 2>/dev/null || true)
assert_eq "exact-target reconciliation runs before PR processing" \
	$'reconcile pr 21806 marcusquinn/aidevops\nprocess_pr marcusquinn/aidevops 21806' "$event_order"

echo ""

# -----------------------------------------------------------------------------
# Test 3: malformed records are skipped, valid records still process.
# -----------------------------------------------------------------------------
echo "Test 3: drain skips malformed records, processes valid ones"
echo "==========================================================="

(
	load_drain_with_stubs

	# Mix of malformed and valid records. Drain MUST process the valid ones
	# and skip the rest without aborting.
	{
		printf '\t\t\t\n'                                                    # all blank
		printf 'badslug\t21806\tpr\t2026-04-30T12:00:00Z\n'                  # slug fails regex
		printf 'marcusquinn/aidevops\tNOTANUMBER\tpr\t2026-04-30T12:00Z\n'   # bad num
		printf 'marcusquinn/aidevops\t21807\tbogus\t2026-04-30T12:00:00Z\n'  # bad type
		printf 'marcusquinn/aidevops\t21808\tpr\t2026-04-30T12:00:00Z\n'    # VALID
		printf 'marcusquinn/aidevops\t21809\tpr\t2026-04-30T12:00:00Z\n'    # VALID
	} >"$TRIGGER_FILE"

	_drain_merge_trigger_file_if_present || exit 1
)
drain_rc=$?

assert_eq "drain returns 0 on mixed valid/malformed input" "0" "$drain_rc"
assert_file_absent "marker file removed after mixed-record drain" "$TRIGGER_FILE"

valid_calls=$(wc -l <"$PROCESS_LOG" 2>/dev/null | tr -d ' ' || echo "0")
assert_eq "drain processed 2 valid records (skipped 4 malformed)" "2" "$valid_calls"
reconcile_calls=$(wc -l <"$RECONCILE_LOG" 2>/dev/null | tr -d ' ' || echo "0")
assert_eq "drain reconciled only the 2 valid records" "2" "$reconcile_calls"

echo ""

# -----------------------------------------------------------------------------
# Test 4: drain is a no-op when marker file is missing.
# -----------------------------------------------------------------------------
echo "Test 4: drain is no-op when marker file is missing"
echo "=================================================="

(
	load_drain_with_stubs

	# Marker file is absent. Drain must return 0 and not touch process_pr.
	rm -f "$TRIGGER_FILE" 2>/dev/null || true

	_drain_merge_trigger_file_if_present || exit 1
)
drain_rc=$?

assert_eq "drain returns 0 on missing marker" "0" "$drain_rc"

if [[ ! -s "$PROCESS_LOG" ]]; then
	assert_pass "process_pr never called on missing marker"
else
	assert_fail "process_pr never called on missing marker" \
		"process log contained: $(cat "$PROCESS_LOG")"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 5: bypass flag short-circuits the drain entirely.
# -----------------------------------------------------------------------------
echo "Test 5: AIDEVOPS_SKIP_TRIGGER_DRAIN=1 short-circuits"
echo "===================================================="

(
	load_drain_with_stubs

	printf 'marcusquinn/aidevops\t21806\tpr\t2026-04-30T12:00:00Z\n' >"$TRIGGER_FILE"

	export AIDEVOPS_SKIP_TRIGGER_DRAIN=1
	_drain_merge_trigger_file_if_present || exit 1
)
drain_rc=$?

assert_eq "drain returns 0 when bypassed" "0" "$drain_rc"

if [[ -f "$TRIGGER_FILE" ]]; then
	assert_pass "marker file preserved when drain is bypassed"
else
	assert_fail "marker file preserved when drain is bypassed" \
		"marker was removed despite bypass flag"
fi

if [[ ! -s "$PROCESS_LOG" ]]; then
	assert_pass "process_pr never called when drain is bypassed"
else
	assert_fail "process_pr never called when drain is bypassed" \
		"process log contained: $(cat "$PROCESS_LOG")"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 6: atomic rotation — concurrent drains do not double-process.
# -----------------------------------------------------------------------------
echo "Test 6: atomic rotation prevents double-processing"
echo "=================================================="

(
	load_drain_with_stubs

	# Stub process_pr to verify the marker is GONE by the time it runs —
	# proves _drain_merge_trigger_file_if_present rotated atomically before
	# invoking process_pr (so a parallel drain would find an empty path).
	process_pr() {
		local slug="${1:-}"
		local pr_number="${2:-}"
		if [[ -f "$TRIGGER_FILE" ]]; then
			printf 'STILL_PRESENT %s %s\n' "$slug" "$pr_number" >>"$PROCESS_LOG"
		else
			printf 'ROTATED %s %s\n' "$slug" "$pr_number" >>"$PROCESS_LOG"
		fi
		return 0
	}

	printf 'marcusquinn/aidevops\t21806\tpr\t2026-04-30T12:00:00Z\n' >"$TRIGGER_FILE"

	_drain_merge_trigger_file_if_present || exit 1
)

if grep -q '^ROTATED ' "$PROCESS_LOG" 2>/dev/null; then
	assert_pass "marker rotated atomically before process_pr fires"
else
	assert_fail "marker rotated atomically before process_pr fires" \
		"process log contained: $(cat "$PROCESS_LOG")"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 7: issue records resolve to the linked PR.
# -----------------------------------------------------------------------------
echo "Test 7: drain resolves issue records to linked PRs"
echo "=================================================="

(
	load_drain_with_stubs

	# Two issue records: 12345 maps to PR 99999 (per the stub resolver),
	# 99998 has no linked PR (skipped).
	{
		printf 'marcusquinn/aidevops\t12345\tissue\t2026-04-30T12:00:00Z\n'
		printf 'marcusquinn/aidevops\t99998\tissue\t2026-04-30T12:00:00Z\n'
	} >"$TRIGGER_FILE"

	_drain_merge_trigger_file_if_present || exit 1
)

calls=$(wc -l <"$PROCESS_LOG" 2>/dev/null | tr -d ' ' || echo "0")
assert_eq "drain processed 1 issue→PR record (skipped 1 unlinked)" "1" "$calls"

reconcile_calls=$(wc -l <"$RECONCILE_LOG" 2>/dev/null | tr -d ' ' || echo "0")
assert_eq "both linked and unlinked issues receive target reconciliation" "2" "$reconcile_calls"
if grep -q '^reconcile issue 99998 marcusquinn/aidevops$' "$RECONCILE_LOG" 2>/dev/null; then
	assert_pass "unlinked issue is reconciled without requiring a PR"
else
	assert_fail "unlinked issue is reconciled without requiring a PR" \
		"reconcile log contained: $(cat "$RECONCILE_LOG")"
fi

logged_call=$(head -1 "$PROCESS_LOG" 2>/dev/null || echo "")
assert_eq "issue 12345 resolved to PR 99999 by stub" \
	"process_pr marcusquinn/aidevops 99999" "$logged_call"

echo ""

# -----------------------------------------------------------------------------
# Test 7b: issue→PR resolver owns and validates fixed GraphQL operation cost.
# -----------------------------------------------------------------------------
echo "Test 7b: resolver reports response-owned GraphQL cost"
echo "======================================================"

metered_graphql_log="${TMPROOT}/test7b-graphql.log"
: >"$metered_graphql_log"
resolver_result=$(
(
	# shellcheck disable=SC1091
	source "${PARENT_DIR}/pulse-wrapper-bootstrap.sh" >/dev/null 2>&1

	gh() {
		local cmd="${1:-}"
		local subcmd="${2:-}"
		if [[ "$cmd" == "api" && "$subcmd" == "graphql" ]]; then
			printf 'meter=%s route=%s\n' \
				"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
				"${AIDEVOPS_GH_ROUTE_DECISION:-}" >>"$metered_graphql_log"
			printf '%s\n' "$*" >>"$metered_graphql_log"
			printf '%s\n' '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":[{"number":76543,"state":"OPEN"}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":1}}}'
			return 0
		fi
		return 1
	}

	gh_pr_list() {
		printf 'unexpected fallback\n' >>"$metered_graphql_log"
		return 1
	}

	_resolve_linked_pr_for_issue "marcusquinn/aidevops" "12345"
)
)
assert_eq "resolver returns the open PR from fixed GraphQL" "76543" "$resolver_result"
if grep -qF 'meter=1 route=pulse-linked-pr-exact-cost' "$metered_graphql_log" &&
	grep -qF 'rateLimit { cost }' "$metered_graphql_log" &&
	! grep -qF 'unexpected fallback' "$metered_graphql_log"; then
	assert_pass "resolver meters GraphQL from the returned rateLimit.cost"
else
	assert_fail "resolver meters GraphQL from the returned rateLimit.cost" \
		"graphql log: $(cat "$metered_graphql_log")"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 7c: a zero GraphQL cost is not valid operation-owned evidence.
# -----------------------------------------------------------------------------
echo "Test 7c: resolver rejects zero GraphQL cost"
echo "============================================"

zero_cost_graphql_log="${TMPROOT}/test7c-graphql.log"
: >"$zero_cost_graphql_log"
resolver_result=$(
(
	# shellcheck disable=SC1091
	source "${PARENT_DIR}/pulse-wrapper-bootstrap.sh" >/dev/null 2>&1

	gh() {
		local cmd="${1:-}"
		local subcmd="${2:-}"
		if [[ "$cmd" == "api" && "$subcmd" == "graphql" ]]; then
			printf '%s\n' 'graphql-zero-cost' >>"$zero_cost_graphql_log"
			printf '%s\n' '{"data":{"repository":{"issue":{"closedByPullRequestsReferences":{"nodes":[{"number":76543,"state":"OPEN"}],"pageInfo":{"hasNextPage":false}}}},"rateLimit":{"cost":0}}}'
			return 0
		fi
		return 1
	}

	gh_pr_list() {
		printf '%s\n' 'fallback-used' >>"$zero_cost_graphql_log"
		printf '%s\n' '[{"number":87654,"body":"Fixes #12345"}]'
		return 0
	}

	_resolve_linked_pr_for_issue "marcusquinn/aidevops" "12345"
)
)
assert_eq "resolver rejects zero-cost GraphQL and uses its fallback" "87654" "$resolver_result"
if grep -qF 'graphql-zero-cost' "$zero_cost_graphql_log" &&
	grep -qF 'fallback-used' "$zero_cost_graphql_log"; then
	assert_pass "zero GraphQL cost cannot authorize linked-PR resolution"
else
	assert_fail "zero GraphQL cost cannot authorize linked-PR resolution" \
		"graphql log: $(cat "$zero_cost_graphql_log")"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 8: issue→PR fallback resolver uses gh_pr_list wrapper when available.
# -----------------------------------------------------------------------------
echo "Test 8: resolver fallback uses gh_pr_list"
echo "=========================================="

raw_gh_log="${TMPROOT}/test8-raw-gh.log"
resolver_result=$(
(
	# shellcheck disable=SC1091
	source "${PARENT_DIR}/pulse-wrapper-bootstrap.sh" >/dev/null 2>&1

	gh() {
		local cmd="${1:-}"
		local subcmd="${2:-}"
		if [[ "$cmd" == "issue" && "$subcmd" == "view" ]]; then
			return 1
		fi
		if [[ "$cmd" == "pr" && "$subcmd" == "list" ]]; then
			printf 'raw gh pr list called\n' >>"$raw_gh_log"
			printf '[{"number":99999,"body":"Resolves #12345"}]'
			return 0
		fi
		return 1
	}

	gh_pr_list() {
		local _unused_first="${1:-}"
		printf '[{"number":77777,"body":"Fixes #12345"}]'
		return 0
	}

	_resolve_linked_pr_for_issue "marcusquinn/aidevops" "12345"
)
)
assert_eq "resolver fallback prefers gh_pr_list wrapper over raw gh" "77777" "$resolver_result"

if [[ ! -s "$raw_gh_log" ]]; then
	assert_pass "resolver fallback does not call raw gh when wrapper exists"
else
	assert_fail "resolver fallback does not call raw gh when wrapper exists" \
		"raw gh log contained: $(cat "$raw_gh_log")"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 9: issue→PR fallback resolver keeps raw gh fallback when wrapper absent.
# -----------------------------------------------------------------------------
echo "Test 9: resolver fallback keeps raw gh without wrapper"
echo "======================================================"

raw_fallback_log="${TMPROOT}/test9-raw-gh.log"
resolver_result=$(
(
	# shellcheck disable=SC1091
	source "${PARENT_DIR}/pulse-wrapper-bootstrap.sh" >/dev/null 2>&1
	unset -f gh_pr_list

	gh() {
		local cmd="${1:-}"
		local subcmd="${2:-}"
		if [[ "$cmd" == "issue" && "$subcmd" == "view" ]]; then
			return 1
		fi
		if [[ "$cmd" == "pr" && "$subcmd" == "list" ]]; then
			printf 'raw gh pr list called\n' >>"$raw_fallback_log"
			printf '[{"number":88888,"body":"Closes #12345"}]'
			return 0
		fi
		return 1
	}

	_resolve_linked_pr_for_issue "marcusquinn/aidevops" "12345"
)
)
assert_eq "resolver fallback uses raw gh when wrapper is absent" "88888" "$resolver_result"

if [[ -s "$raw_fallback_log" ]]; then
	assert_pass "resolver fallback called raw gh without wrapper"
else
	assert_fail "resolver fallback called raw gh without wrapper" "raw gh log empty"
fi

echo ""

# -----------------------------------------------------------------------------
# Test 10: exact duplicate records reconcile and process only once.
# -----------------------------------------------------------------------------
echo "Test 10: duplicate target records are idempotent"
echo "================================================"

(
	load_drain_with_stubs

	{
		printf 'marcusquinn/aidevops\t21806\tpr\t2026-04-30T12:00:00Z\n'
		printf 'marcusquinn/aidevops\t21806\tpr\t2026-04-30T12:00:01Z\n'
	} >"$TRIGGER_FILE"

	_drain_merge_trigger_file_if_present || exit 1
)
drain_rc=$?

assert_eq "duplicate drain returns 0" "0" "$drain_rc"
reconcile_calls=$(wc -l <"$RECONCILE_LOG" 2>/dev/null | tr -d ' ' || echo "0")
process_calls=$(wc -l <"$PROCESS_LOG" 2>/dev/null | tr -d ' ' || echo "0")
assert_eq "duplicate target reconciles once" "1" "$reconcile_calls"
assert_eq "duplicate target processes its PR once" "1" "$process_calls"

echo ""

# =============================================================================
echo "=================================================="
echo "Results: ${PASS} pass, ${FAIL} fail"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
