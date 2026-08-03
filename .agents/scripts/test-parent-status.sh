#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-parent-status.sh — Stub-based test harness for parent-status-helper.sh (t2741)
#
# Model: mirrors test-issue-sync-lib.sh (t1983) and test-privacy-guard.sh (t1969).
# No network, no `gh` CLI dependency — uses PARENT_STATUS_GH_OFFLINE=1 with
# PARENT_STATUS_STUB_DIR pointing to canned JSON fixtures in a tmp directory.
#
# Tests:
#   1.  Human output: title, phases count line, phase rows, next action present
#   2.  JSON output: parses as valid JSON, contains expected keys
#   3.  Phases section parsed: 7 planned phases produces 7 rows
#   4.  Filed phases: children from sub-issues list appear as numbered issues
#   5.  Merged phase: PR with mergedAt shows MERGED in output
#   6.  Open PR: PR with state OPEN and no mergedAt shows OPEN in output
#   7.  NOT FILED phase: phase without a corresponding child shows NOT FILED
#   8.  Next action — in-flight PR: output mentions merge PR
#   9.  Error on missing parent-task label (non-offline mode stubbed)
#   10. Error on missing issue number argument
#   11. --json output contains "phases" array
#   12. --json phases array length matches planned count
#
# Exit 0 = all tests pass, 1 = at least one failure.

set -u

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	BLUE=$'\033[0;34m'
	YELLOW=$'\033[1;33m'
	NC=$'\033[0m'
else
	GREEN="" RED="" BLUE="" YELLOW="" NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

pass() {
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$GREEN" "$NC" "$1"
	return 0
}

fail() {
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$RED" "$NC" "$1"
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/parent-status-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf '%sERROR%s: helper not found at %s\n' "$RED" "$NC" "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# =============================================================================
# Fixture builder — create canned JSON files in STUB_DIR
# =============================================================================

STUB_DIR="${TMP}/stubs"
mkdir -p "$STUB_DIR"

# Parent issue body with 7 phases (matching the issue example)
PARENT_BODY='## Task

Parent task for testing.

## Phases

Phase 1 — Inventory
Phase 2 — needs-credentials label
Phase 3 — backfill 4 at-risk issues: #20503
Phase 4 — pulse-dispatch-core.sh flip
Phase 5 — strip label-adding
Phase 6 — invert self-assign carveouts
Phase 7 — doc sweep

## Children

- #20503
- #20510
'

# issue-20402.json — parent issue with parent-task label
cat >"$STUB_DIR/issue-20402.json" <<EOF
{
  "number": 20402,
  "title": "t2721: Remove / invert auto-dispatch default",
  "state": "OPEN",
  "body": $(printf '%s' "$PARENT_BODY" | jq -Rs '.'),
  "labels": [
    {"name": "parent-task"},
    {"name": "origin:worker"}
  ]
}
EOF

# sub-issues-20402.json — two children
cat >"$STUB_DIR/sub-issues-20402.json" <<'EOF'
[
  {"number": 20410, "title": "t2721.1: Phase 1 — Inventory"},
  {"number": 20415, "title": "t2721.2: Phase 2 — needs-credentials label"}
]
EOF

# issue-20410.json — child 1 (closed/merged via PR)
cat >"$STUB_DIR/issue-20410.json" <<'EOF'
{
  "number": 20410,
  "title": "t2721.1: Phase 1 — Inventory",
  "state": "CLOSED",
  "body": "Parent: #20402\n...",
  "labels": []
}
EOF

# pr-for-20410.json — PR for child 1, merged
cat >"$STUB_DIR/pr-for-20410.json" <<'EOF'
{
  "number": 20415,
  "title": "t2721.1: Phase 1 Inventory impl",
  "state": "CLOSED",
  "mergedAt": "2026-04-21T10:00:00Z",
  "mergeStateStatus": "MERGED"
}
EOF

# issue-20415.json — child 2 (open, PR open)
cat >"$STUB_DIR/issue-20415.json" <<'EOF'
{
  "number": 20415,
  "title": "t2721.2: Phase 2 needs-credentials",
  "state": "OPEN",
  "body": "Parent: #20402\n...",
  "labels": []
}
EOF

# pr-for-20415.json — open PR for child 2
cat >"$STUB_DIR/pr-for-20415.json" <<'EOF'
{
  "number": 20417,
  "title": "t2721.2: Phase 2 impl",
  "state": "OPEN",
  "mergedAt": null,
  "mergeStateStatus": "MERGEABLE"
}
EOF

# issue-20503.json — child referenced in body (body-only, not in sub-issues)
cat >"$STUB_DIR/issue-20503.json" <<'EOF'
{
  "number": 20503,
  "title": "t2721.3: Phase 3 backfill",
  "state": "OPEN",
  "body": "Parent: #20402",
  "labels": []
}
EOF

# pr-for-20503.json — no PR yet
cat >"$STUB_DIR/pr-for-20503.json" <<'EOF'
null
EOF

# issue-20510.json
cat >"$STUB_DIR/issue-20510.json" <<'EOF'
{
  "number": 20510,
  "title": "t2721.7: Phase 7 doc sweep",
  "state": "OPEN",
  "body": "Parent: #20402",
  "labels": []
}
EOF

# pr-for-20510.json
cat >"$STUB_DIR/pr-for-20510.json" <<'EOF'
null
EOF

# GH#29325 regression: five display phases map to a 15-child closure set.
jq -n '{number:30000,title:"Fifteen-child parent",state:"OPEN",body:("## Phases\n\nPhase 1 — Discovery\nPhase 2 — Build\nPhase 3 — Migrate\nPhase 4 — Verify\nPhase 5 — Closeout\n\n<!-- parent-close-contract: expected-children=15 -->"),labels:[{name:"parent-task"}]}' \
	>"$STUB_DIR/issue-30000.json"
jq -n '[range(30001;30016) | {number:.,title:("Child " + (.|tostring))}]' \
	>"$STUB_DIR/sub-issues-30000.json"
child_num=30001
while [[ "$child_num" -le 30015 ]]; do
	if [[ "$child_num" -le 30006 ]]; then
		jq -n --argjson number "$child_num" \
			'{number:$number,title:("Child " + ($number|tostring)),state:"CLOSED",stateReason:"COMPLETED",labels:[]}' \
			>"$STUB_DIR/issue-${child_num}.json"
		jq -n --argjson number "$((child_num + 1000))" \
			'{number:$number,state:"CLOSED",mergedAt:"2026-08-01T00:00:00Z"}' \
			>"$STUB_DIR/pr-for-${child_num}.json"
	else
		labels='[]'
		[[ "$child_num" -eq 30008 ]] && labels='[{"name":"status:blocked"}]'
		jq -n --argjson number "$child_num" --argjson labels "$labels" \
			'{number:$number,title:("Child " + ($number|tostring)),state:"OPEN",stateReason:null,labels:$labels}' \
			>"$STUB_DIR/issue-${child_num}.json"
		if [[ "$child_num" -eq 30007 ]]; then
			jq -n '{number:32007,state:"OPEN",mergedAt:null}' >"$STUB_DIR/pr-for-${child_num}.json"
		else
			printf 'null\n' >"$STUB_DIR/pr-for-${child_num}.json"
		fi
	fi
	child_num=$((child_num + 1))
done

# Complete + superseded children are both terminal for closure readiness.
jq -n '{number:30100,title:"Complete parent",state:"OPEN",body:"<!-- parent-close-contract: expected-children=2 -->",labels:[{name:"parent-task"}]}' \
	>"$STUB_DIR/issue-30100.json"
printf '%s\n' '[{"number":30101},{"number":30102}]' >"$STUB_DIR/sub-issues-30100.json"
printf '%s\n' '{"number":30101,"title":"Completed child","state":"CLOSED","stateReason":"COMPLETED","labels":[]}' \
	>"$STUB_DIR/issue-30101.json"
printf '%s\n' '{"number":30102,"title":"Superseded child","state":"CLOSED","stateReason":"NOT_PLANNED","labels":[]}' \
	>"$STUB_DIR/issue-30102.json"
printf '%s\n' '{"number":32101,"state":"CLOSED","mergedAt":"2026-08-01T00:00:00Z"}' \
	>"$STUB_DIR/pr-for-30101.json"
printf 'null\n' >"$STUB_DIR/pr-for-30102.json"

# Expected-child, incomplete-read, blocked, and plain-open recommendation cases.
jq -n '{number:30200,title:"Missing expected child",state:"OPEN",body:"<!-- parent-close-contract: expected-children=3 -->",labels:[{name:"parent-task"}]}' \
	>"$STUB_DIR/issue-30200.json"
printf '%s\n' '[{"number":30101},{"number":30102}]' >"$STUB_DIR/sub-issues-30200.json"
jq -n '{number:30300,title:"Incomplete child read",state:"OPEN",body:"<!-- parent-close-contract: expected-children=1 -->",labels:[{name:"parent-task"}]}' \
	>"$STUB_DIR/issue-30300.json"
printf '%s\n' '[{"number":30301}]' >"$STUB_DIR/sub-issues-30300.json"
for parent_num in 30400 30500; do
	jq -n --argjson number "$parent_num" \
		'{number:$number,title:"Open child parent",state:"OPEN",body:"<!-- parent-close-contract: expected-children=1 -->",labels:[{name:"parent-task"}]}' \
		>"$STUB_DIR/issue-${parent_num}.json"
	printf '[{"number":%s}]\n' "$((parent_num + 1))" >"$STUB_DIR/sub-issues-${parent_num}.json"
done
printf '%s\n' '{"number":30401,"title":"Blocked child","state":"OPEN","labels":[{"name":"status:blocked"}]}' \
	>"$STUB_DIR/issue-30401.json"
printf '%s\n' '{"number":30501,"title":"Open child","state":"OPEN","labels":[]}' \
	>"$STUB_DIR/issue-30501.json"
printf 'null\n' >"$STUB_DIR/pr-for-30401.json"
printf 'null\n' >"$STUB_DIR/pr-for-30501.json"

# Malformed native data must remain fail-closed even when a complete body-linked
# child exists. Canonical phase rows also remain part of the close contract when
# a legacy parent predates explicit parent-close-contract markers.
jq -n '{number:30600,title:"Malformed native data",state:"OPEN",body:"## Children\n\n- #30601\n\n<!-- parent-close-contract: complete -->",labels:[{name:"parent-task"}]}' \
	>"$STUB_DIR/issue-30600.json"
printf '%s\n' '{}' >"$STUB_DIR/sub-issues-30600.json"
printf '%s\n' '{"number":30601,"title":"Complete body child","state":"CLOSED","stateReason":"COMPLETED","labels":[]}' \
	>"$STUB_DIR/issue-30601.json"
printf 'null\n' >"$STUB_DIR/pr-for-30601.json"
jq -n '{number:30700,title:"Legacy phase plan",state:"OPEN",body:"## Phases\n\nPhase 1 — Complete #30701\nPhase 2 — Not filed",labels:[{name:"parent-task"}]}' \
	>"$STUB_DIR/issue-30700.json"
printf '%s\n' '[{"number":30701}]' >"$STUB_DIR/sub-issues-30700.json"
printf '%s\n' '{"number":30701,"title":"Complete phase","state":"CLOSED","stateReason":"COMPLETED","labels":[]}' \
	>"$STUB_DIR/issue-30701.json"
printf 'null\n' >"$STUB_DIR/pr-for-30701.json"

# =============================================================================
# Test runner
# =============================================================================

run_helper() {
	# Runs the helper in offline stub mode, returns stdout
	PARENT_STATUS_GH_OFFLINE=1 PARENT_STATUS_STUB_DIR="$STUB_DIR" \
		bash "$HELPER" "$@" 2>/dev/null
	return 0
}

run_helper_stderr() {
	# Returns stderr only
	PARENT_STATUS_GH_OFFLINE=1 PARENT_STATUS_STUB_DIR="$STUB_DIR" \
		bash "$HELPER" "$@" >/dev/null 2>&1
	return 0
}

printf '%sRunning parent-status-helper tests%s\n\n' "$BLUE" "$NC"

# =============================================================================
# Test 1: Human output — title line present
# =============================================================================
output=$(run_helper 20402 --repo marcusquinn/aidevops)
if printf '%s' "$output" | grep -q 'Parent: #20402'; then
	pass "1: Human output contains 'Parent: #20402' title line"
else
	fail "1: Human output missing 'Parent: #20402' (got: $(printf '%s' "$output" | head -3))"
fi

# =============================================================================
# Test 2: Human output — phases count line present
# =============================================================================
if printf '%s' "$output" | grep -qE 'Phases: [0-9]+ planned'; then
	pass "2: Human output contains 'Phases: N planned' line"
else
	fail "2: Human output missing 'Phases: N planned' line"
fi

# =============================================================================
# Test 3: Phases section — 7 planned phases
# =============================================================================
phases_total=$(printf '%s' "$output" | grep -oE 'Phases: ([0-9]+) planned' | grep -oE '[0-9]+' | head -1)
if [[ "$phases_total" == "7" ]]; then
	pass "3: 7 planned phases detected from ## Phases section"
else
	fail "3: Expected 7 planned phases, got: '$phases_total'"
fi

# =============================================================================
# Test 4: Filed children appear as #NNN references
# =============================================================================
if printf '%s' "$output" | grep -qE '#[0-9]+'; then
	pass "4: Filed children appear as #NNN references in output"
else
	fail "4: No #NNN child references found in output"
fi

# =============================================================================
# Test 5: Merged phase shows MERGED
# =============================================================================
if printf '%s' "$output" | grep -q 'MERGED'; then
	pass "5: Merged PR phase shows MERGED in output"
else
	fail "5: MERGED not found in output (merged PR phase not rendered)"
fi

# =============================================================================
# Test 6: Open PR shows OPEN
# =============================================================================
if printf '%s' "$output" | grep -q 'OPEN'; then
	pass "6: Open PR phase shows OPEN in output"
else
	fail "6: OPEN not found in output (open PR phase not rendered)"
fi

# =============================================================================
# Test 7: Unfiled phases show NOT FILED
# =============================================================================
if printf '%s' "$output" | grep -q 'NOT FILED'; then
	pass "7: Unfiled phases show 'NOT FILED' in output"
else
	fail "7: 'NOT FILED' not found in output for unmatched phases"
fi

# =============================================================================
# Test 8: Next action mentions merge PR when one is in-flight
# =============================================================================
if printf '%s' "$output" | grep -qi 'next action'; then
	pass "8: 'Next action:' line present in output"
else
	fail "8: 'Next action:' line missing from output"
fi

# =============================================================================
# Test 9: Error when issue number is missing
# =============================================================================
err_out=$(PARENT_STATUS_GH_OFFLINE=1 PARENT_STATUS_STUB_DIR="$STUB_DIR" \
	bash "$HELPER" 2>&1 || true)
if printf '%s' "$err_out" | grep -qi 'required\|usage\|issue'; then
	pass "9: Error message shown when issue number is missing"
else
	fail "9: Expected error on missing issue number, got: '$err_out'"
fi

# =============================================================================
# Test 10: Error on non-numeric argument
# =============================================================================
err_out2=$(PARENT_STATUS_GH_OFFLINE=1 PARENT_STATUS_STUB_DIR="$STUB_DIR" \
	bash "$HELPER" "notanumber" 2>&1 || true)
if printf '%s' "$err_out2" | grep -qi 'integer\|number\|invalid'; then
	pass "10: Error shown for non-numeric issue argument"
else
	fail "10: Expected error on non-numeric argument, got: '$err_out2'"
fi

# =============================================================================
# Test 11: --json output is valid JSON
# =============================================================================
json_output=$(run_helper 20402 --repo marcusquinn/aidevops --json)
if printf '%s' "$json_output" | jq '.' >/dev/null 2>&1; then
	pass "11: --json output is valid JSON"
else
	fail "11: --json output is not valid JSON"
fi

# =============================================================================
# Test 12: --json output contains "phases" array
# =============================================================================
json_has_phases=$(printf '%s' "$json_output" | jq 'has("phases")' 2>/dev/null || echo "false")
if [[ "$json_has_phases" == "true" ]]; then
	pass "12: --json output contains 'phases' array key"
else
	fail "12: --json output missing 'phases' key"
fi

# =============================================================================
# Test 13: --json phases array length matches planned count
# =============================================================================
json_phases_len=$(printf '%s' "$json_output" | jq '.phases | length' 2>/dev/null || echo 0)
if [[ "$json_phases_len" == "7" ]]; then
	pass "13: --json phases array has 7 entries matching planned count"
else
	fail "13: Expected 7 phases in JSON, got: $json_phases_len"
fi

# =============================================================================
# Test 14: --json contains parent_number, parent_title, next_action
# =============================================================================
has_keys=$(printf '%s' "$json_output" | \
	jq 'has("parent_number") and has("parent_title") and has("next_action")' 2>/dev/null || echo "false")
if [[ "$has_keys" == "true" ]]; then
	pass "14: --json output contains parent_number, parent_title, next_action"
else
	fail "14: --json output missing required top-level keys"
fi

# =============================================================================
# Test 15: --json phases_total matches human output
# =============================================================================
json_phases_total=$(printf '%s' "$json_output" | jq '.phases_total' 2>/dev/null || echo 0)
if [[ "$json_phases_total" == "7" ]]; then
	pass "15: --json phases_total=7"
else
	fail "15: Expected phases_total=7, got: $json_phases_total"
fi

# =============================================================================
# Tests 16-21: GH#29325 closure-readiness recommendations
# =============================================================================
fifteen_output=$(run_helper 30000 --repo marcusquinn/aidevops)
if printf '%s' "$fifteen_output" | grep -q 'Phases: 5 planned, 15 filed, 6 merged, 1 in-flight' &&
	printf '%s' "$fifteen_output" | grep -q '15 filed, 9 remaining open' &&
	printf '%s' "$fifteen_output" | grep -q 'merge PR #32007' &&
	! printf '%s' "$fifteen_output" | grep -q 'close the parent issue'; then
	pass "16: 15-child/5-phase parent reports nine open children without recommending closure"
else
	fail "16: 15-child/5-phase parent produced an unsafe recommendation"
fi

complete_output=$(run_helper 30100 --repo marcusquinn/aidevops)
if printf '%s' "$complete_output" | grep -q '0 remaining open, 1 superseded' &&
	printf '%s' "$complete_output" | grep -q 'close the parent issue'; then
	pass "17: completed and superseded child set recommends closure"
else
	fail "17: terminal completed/superseded set did not recommend closure"
fi

missing_output=$(run_helper 30200 --repo marcusquinn/aidevops)
if printf '%s' "$missing_output" | grep -q 'File 1 remaining expected child issue'; then
	pass "18: expected-children contract reports a missing child"
else
	fail "18: expected-children contract did not block closure"
fi

incomplete_output=$(run_helper 30300 --repo marcusquinn/aidevops)
if printf '%s' "$incomplete_output" | grep -q 'Child state retrieval incomplete' &&
	! printf '%s' "$incomplete_output" | grep -q 'close the parent issue'; then
	pass "19: incomplete child API data fails closed"
else
	fail "19: incomplete child API data produced an unsafe recommendation"
fi

blocked_output=$(run_helper 30400 --repo marcusquinn/aidevops)
if printf '%s' "$blocked_output" | grep -q 'resolve blockers on child #30401'; then
	pass "20: blocked child set recommends resolving the next blocker"
else
	fail "20: blocked child set did not identify the next blocker"
fi

open_output=$(run_helper 30500 --repo marcusquinn/aidevops)
if printf '%s' "$open_output" | grep -q '1 child issue(s) remain open — continue child #30501'; then
	pass "21: open child set identifies the next child action"
else
	fail "21: open child set did not identify the next child action"
fi

malformed_output=$(run_helper 30600 --repo marcusquinn/aidevops)
if printf '%s' "$malformed_output" | grep -q 'Child state retrieval incomplete' &&
	! printf '%s' "$malformed_output" | grep -q 'close the parent issue'; then
	pass "22: malformed native sub-issue data fails closed"
else
	fail "22: malformed native sub-issue data produced an unsafe recommendation"
fi

legacy_phase_output=$(run_helper 30700 --repo marcusquinn/aidevops)
if printf '%s' "$legacy_phase_output" | grep -q 'Parent close contract is incomplete (unfiled-phases)' &&
	! printf '%s' "$legacy_phase_output" | grep -q 'close the parent issue'; then
	pass "23: unfiled canonical phase blocks closure without an explicit marker"
else
	fail "23: legacy canonical phase plan produced an unsafe recommendation"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed.%s\n' "$GREEN" "$TESTS_RUN" "$NC"
	exit 0
else
	printf '%s%d of %d tests FAILED.%s\n' "$RED" "$TESTS_FAILED" "$TESTS_RUN" "$NC"
	exit 1
fi
