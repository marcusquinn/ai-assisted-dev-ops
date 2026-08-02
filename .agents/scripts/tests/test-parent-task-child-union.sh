#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted grep patterns are literal by design
#
# test-parent-task-child-union.sh — GH#20872 regression
#
# Verifies that child detection in `_pir_collect_parent_child_evidence`
# (pulse-issue-reconcile-actions.sh) unions the child sources instead of taking
# the first non-empty one.
#
# Pre-GH#20872 behaviour: graph→body→prose first-wins. A graph with 1 child
# silently masked a body listing 4 children — the `child_count >= 2` guard in
# `_try_close_parent_tracker` then blocked auto-close. Real-world hits during
# v3.11.1 deploy verification: #20559 (graph=1, body=4 closed children) and
# #20581 (graph=1, body=2 closed children) both stayed open until the
# maintainer manually closed them.
#
# Test strategy: inline the union logic exactly as it appears in the collector
# helper and verify behaviour against synthetic graph/body/prose
# inputs. Pure string processing — no gh stubs needed. The structural test
# file (test-parent-task-lifecycle.sh) verifies the union code is wired into
# the production function body via grep on the source.

set -u

if [[ -t 1 ]]; then
	TEST_GREEN=$'\033[0;32m'
	TEST_RED=$'\033[0;31m'
	TEST_BLUE=$'\033[0;34m'
	TEST_NC=$'\033[0m'
else
	TEST_GREEN="" TEST_RED="" TEST_BLUE="" TEST_NC=""
fi

TESTS_RUN=0
TESTS_FAILED=0

assert_eq() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected: $expected"
		echo "  actual:   $actual"
	fi
	return 0
}

# --- Inline union logic (mirrors _action_cpt_single GH#20872 block) ---
# Args: $1=parent_num $2=graph_nums $3=body_nums $4=prose_nums
# Stdout: numeric child IDs (one per line, sorted, deduped, self-ref dropped)
union_nums() {
	local parent_num="$1" g="$2" b="$3" p="$4"
	printf '%s\n%s\n%s\n' "$g" "$b" "$p" \
		| grep -E '^[0-9]+$' | sort -un | grep -v "^${parent_num}$" || true
	return 0
}

# Args: same as union_nums
# Stdout: source label (e.g. "graph+body+prose" or "none")
union_src() {
	local g="$2" b="$3" p="$4"
	local src=""
	[[ -n "$g" ]] && src="${src:+${src}+}graph"
	[[ -n "$b" ]] && src="${src:+${src}+}body"
	[[ -n "$p" ]] && src="${src:+${src}+}prose"
	printf '%s' "${src:-none}"
	return 0
}

echo "${TEST_BLUE}=== GH#20872: child source union tests ===${TEST_NC}"
echo ""

# ============================================================
# Scenario 1: #20559 shape — graph=1, body=4. Pre-fix: graph wins, count=1,
# auto-close blocked. Post-fix: union={20702,20703,20704,20768}, count=4, eligible.
# ============================================================
PARENT="20559"
GRAPH_1=$(printf '20768\n')
BODY_1=$(printf '20702\n20703\n20704\n20768\n')
PROSE_1=""

result=$(union_nums "$PARENT" "$GRAPH_1" "$BODY_1" "$PROSE_1" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S1a: #20559 shape — union returns all 4 children" \
	"20702 20703 20704 20768" "$result"

count=$(union_nums "$PARENT" "$GRAPH_1" "$BODY_1" "$PROSE_1" | grep -c .)
assert_eq "S1b: #20559 shape — child_count = 4 (passes >=2 guard)" "4" "$count"

src=$(union_src "$PARENT" "$GRAPH_1" "$BODY_1" "$PROSE_1")
assert_eq "S1c: #20559 shape — source label is graph+body" "graph+body" "$src"

# ============================================================
# Scenario 2: #20581 shape — graph=1, body=2.
# ============================================================
PARENT="20581"
GRAPH_2=$(printf '20594\n')
BODY_2=$(printf '20594\n20707\n')
PROSE_2=""

result=$(union_nums "$PARENT" "$GRAPH_2" "$BODY_2" "$PROSE_2" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S2a: #20581 shape — union returns both children deduped" \
	"20594 20707" "$result"

count=$(union_nums "$PARENT" "$GRAPH_2" "$BODY_2" "$PROSE_2" | grep -c .)
assert_eq "S2b: #20581 shape — child_count = 2 (passes >=2 guard)" "2" "$count"

# ============================================================
# Scenario 3: graph-only (no body listing). Source label drops body.
# ============================================================
PARENT="100"
GRAPH_3=$(printf '101\n102\n103\n')
BODY_3=""
PROSE_3=""

result=$(union_nums "$PARENT" "$GRAPH_3" "$BODY_3" "$PROSE_3" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S3a: graph-only — union returns 3 graph children" "101 102 103" "$result"
src=$(union_src "$PARENT" "$GRAPH_3" "$BODY_3" "$PROSE_3")
assert_eq "S3b: graph-only — source label is graph" "graph" "$src"

# ============================================================
# Scenario 4: body-only (legacy parent, no graph wiring).
# ============================================================
PARENT="200"
GRAPH_4=""
BODY_4=$(printf '201\n202\n')
PROSE_4=""

result=$(union_nums "$PARENT" "$GRAPH_4" "$BODY_4" "$PROSE_4" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S4a: body-only — union returns 2 body children" "201 202" "$result"
src=$(union_src "$PARENT" "$GRAPH_4" "$BODY_4" "$PROSE_4")
assert_eq "S4b: body-only — source label is body" "body" "$src"

# ============================================================
# Scenario 5: prose-only (no Children section, no graph).
# ============================================================
PARENT="300"
GRAPH_5=""
BODY_5=""
PROSE_5=$(printf '301\n302\n')

result=$(union_nums "$PARENT" "$GRAPH_5" "$BODY_5" "$PROSE_5" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S5a: prose-only — union returns 2 prose children" "301 302" "$result"
src=$(union_src "$PARENT" "$GRAPH_5" "$BODY_5" "$PROSE_5")
assert_eq "S5b: prose-only — source label is prose" "prose" "$src"

# ============================================================
# Scenario 6: all three sources contribute — full label.
# ============================================================
PARENT="400"
GRAPH_6=$(printf '401\n')
BODY_6=$(printf '402\n')
PROSE_6=$(printf '403\n')

result=$(union_nums "$PARENT" "$GRAPH_6" "$BODY_6" "$PROSE_6" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S6a: all three sources — union returns 3 children" "401 402 403" "$result"
src=$(union_src "$PARENT" "$GRAPH_6" "$BODY_6" "$PROSE_6")
assert_eq "S6b: all three sources — source label is graph+body+prose" \
	"graph+body+prose" "$src"

# ============================================================
# Scenario 7: parent self-reference dropped from all sources.
# ============================================================
PARENT="500"
GRAPH_7=$(printf '500\n501\n')
BODY_7=$(printf '500\n502\n')
PROSE_7=""

result=$(union_nums "$PARENT" "$GRAPH_7" "$BODY_7" "$PROSE_7" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S7: parent self-ref (#500) dropped from union" "501 502" "$result"

# ============================================================
# Scenario 8: empty everything — none label, empty result.
# ============================================================
PARENT="600"
result=$(union_nums "$PARENT" "" "" "")
assert_eq "S8a: all empty — union returns empty" "" "$result"
src=$(union_src "$PARENT" "" "" "")
assert_eq "S8b: all empty — source label is none" "none" "$src"

# ============================================================
# Scenario 9: dedup across sources — same child in graph and body.
# ============================================================
PARENT="700"
GRAPH_9=$(printf '701\n702\n')
BODY_9=$(printf '701\n702\n703\n')
PROSE_9=""

result=$(union_nums "$PARENT" "$GRAPH_9" "$BODY_9" "$PROSE_9" | tr '\n' ' ' | sed 's/ $//')
assert_eq "S9: dedup across sources — union returns 3 unique children" \
	"701 702 703" "$result"

# ============================================================
# Scenario 10: structural — the production collector must contain the union
# code, not the pre-GH#20872 first-wins chain.
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET="$SCRIPT_DIR/pulse-issue-reconcile-actions.sh"

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

# S10a: the extracted union collector is present in production source
assert_grep_fixed "S10a: production source contains the union collector" \
	'_pir_collect_parent_child_evidence()' "$TARGET"

# S10b: source label uses + joiner
assert_grep_fixed "S10b: source label uses + joiner for composite sources" \
	'source_parts:+${source_parts}+' "$TARGET"

# S10c: union concatenation pattern present
assert_grep_fixed "S10c: union concatenation pattern present" \
	'"$graph_nums" "$body_nums" "$prose_nums"' "$TARGET"

# ============================================================
echo ""
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}=== Results: ${TESTS_RUN}/${TESTS_RUN} passed ===${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}=== Results: ${TESTS_RUN} run, ${TESTS_FAILED} failed ===${TEST_NC}"
	exit 1
fi
