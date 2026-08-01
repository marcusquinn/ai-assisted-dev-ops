#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# shellcheck disable=SC2016  # single-quoted regex patterns are literal by design
#
# test-parent-decomposition-nudge-dedup.sh — regression test for t2572 (GH#20240)
#
# The parent-decomposition nudge dedup check was silently broken since
# introduction: `gh api --paginate ... --slurp --jq "..."` is REJECTED by
# `gh api` with "the --slurp option is not supported with --jq or --template".
# The error was swallowed by `2>/dev/null`, `existing=""` never matched the
# `^[1-9]` regex, and the "post only once" guarantee was voided — every pulse
# cycle re-posted a fresh nudge comment.
#
# Observed impact: 22 identical nudge comments on a single parent-task issue
# across ~30h from two pulse runners (aidevops#20001). 4 identical comments
# on webapp#2546 from two runners within minutes.
#
# Fix: replace `--slurp --jq` with streaming `--paginate --jq | wc -l`
# pattern. --paginate alone emits each page; --jq applies per page. Emit one
# .id per matching comment across all pages and count.
#
# Test coverage:
#   1. No production `gh api` command combines `--slurp` with
#      `--jq`/`--template` (standalone jq after a pipe remains valid)
#   2. The detector catches reordered multiline flags
#   3. _post_parent_decomposition_nudge uses streaming + wc -l pattern
#   4. _compute_parent_nudge_age_hours uses streaming + head -n1 pattern
#   5. _post_parent_decomposition_escalation uses streaming + wc -l pattern
#   6. _post_parent_task_no_markers_warning (issue-sync-lib-compose.sh) uses streaming
#   7. _post_parent_task_no_markers_warning has no --slurp flag
#   8. Idempotency guards retain their intended fail-closed/open semantics
#   9. t2572 provenance comments remain in the fixed modules
#
# Structural grep-based tests; functional end-to-end with a stubbed gh api
# requires sourcing all pulse-wrapper dependencies which is out of scope for
# a regression test. The broken-state detection (no single `gh api` logical
# command combines --slurp with --jq/--template) is the canonical regression
# signal — if the anti-pattern reappears, this test catches it without
# rejecting valid paginated slurp followed by standalone jq.

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

assert_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected pattern: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

assert_no_grep() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if ! grep -qE "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  unexpected pattern found: $pattern"
		echo "  in file:                  $file"
		grep -nE "$pattern" "$file" 2>/dev/null | head -5 | sed 's/^/    /'
	fi
	return 0
}

assert_grep_fixed() {
	local label="$1" pattern="$2" file="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if grep -qF -- "$pattern" "$file" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected literal: $pattern"
		echo "  in file:          $file"
	fi
	return 0
}

has_combined_slurp_and_filter() {
	local source_file="$1"
	if sed -e :a -e '/\\$/N; s/\\\n[[:space:]]*/ /; ta' "$source_file" |
		grep -vE '^[[:space:]]*#' |
		grep -E 'gh[[:space:]]+[[:space:]]*api' |
		grep -F -- '--slurp' |
		grep -Eq -- '(^|[[:space:]])--(jq|template)(=|[[:space:]])'; then
		return 0
	fi
	return 1
}

find_combined_slurp_and_filter_files() {
	local repo_root="$1"
	local relative_file=""
	while IFS= read -r relative_file; do
		case "$relative_file" in
		.agents/scripts/tests/*) continue ;;
		esac
		if has_combined_slurp_and_filter "$repo_root/$relative_file"; then
			printf '%s\n' "$relative_file"
		fi
	done < <(git -C "$repo_root" ls-files --cached --others --exclude-standard '.agents/scripts/*.sh')
	return 0
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AGENTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$AGENTS_DIR/.." && pwd)"
PARENT_RECONCILE="$SCRIPT_DIR/pulse-issue-reconcile-parent.sh"
RECONCILE_ACTIONS="$SCRIPT_DIR/pulse-issue-reconcile-actions.sh"
SYNC_COMPOSE="$SCRIPT_DIR/issue-sync-lib-compose.sh"

for f in "$PARENT_RECONCILE" "$RECONCILE_ACTIONS" "$SYNC_COMPOSE"; do
	if [[ ! -f "$f" ]]; then
		echo "${TEST_RED}FATAL${TEST_NC}: $f not found"
		exit 1
	fi
done

echo "${TEST_BLUE}=== t2572: gh api --slurp+--jq anti-pattern regression tests ===${TEST_NC}"
echo ""

# --- Acceptance criterion 1: no production gh api command combines flags ---
# Collapse backslash-continued logical lines so reordered/multiline flags are
# detected. Scan tracked and untracked production shell files, but exclude test
# fixtures that intentionally model the invalid combination.
TESTS_RUN=$((TESTS_RUN + 1))
anti_pattern_hits=$(find_combined_slurp_and_filter_files "$REPO_ROOT")
if [[ -z "$anti_pattern_hits" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 1: no production gh api command combines --slurp with --jq/--template"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 1: found gh api commands combining --slurp with --jq/--template:"
	echo "$anti_pattern_hits" | sed 's/^/    /'
fi

# Prove the detector handles flags in either order across continued lines.
TESTS_RUN=$((TESTS_RUN + 1))
if has_combined_slurp_and_filter <(printf '%s\n' \
	"gh api --jq '.[]' \\" \
	"  --paginate \\" \
	'  --slurp repos/example/project/issues/1/comments'); then
	echo "${TEST_GREEN}PASS${TEST_NC}: 2: detector catches reordered multiline --slurp/--jq flags"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 2: detector missed reordered multiline --slurp/--jq flags"
fi

# --- _post_parent_decomposition_nudge (parent module) ---

assert_grep_fixed \
	"3: nudge helper uses streaming --jq + .id select" \
	'--jq ".[] | select(.body | contains(\"${marker}\")) | .id"' \
	"$PARENT_RECONCILE"

assert_grep_fixed \
	"4: nudge helper pipes to wc -l | tr -d" \
	'2>/dev/null | wc -l | tr -d' \
	"$PARENT_RECONCILE"

# --- _compute_parent_nudge_age_hours (actions module) ---

assert_grep_fixed \
	"5: nudge-age helper uses streaming + head -n1" \
	'| head -n1) || nudge_created_at=""' \
	"$RECONCILE_ACTIONS"

assert_grep_fixed \
	"6: nudge-age helper selects .created_at without slurp" \
	"--jq '.[] | select(.body | contains(\"<!-- parent-needs-decomposition -->\")) | .created_at'" \
	"$RECONCILE_ACTIONS"

# --- _post_parent_decomposition_escalation (parent module) ---
# Counts occurrences of the streaming pattern — expect 2 (nudge + escalation)
# in pulse-issue-reconcile-parent.sh.
TESTS_RUN=$((TESTS_RUN + 1))
streaming_count=$(grep -cF -- '2>/dev/null | wc -l | tr -d' "$PARENT_RECONCILE" 2>/dev/null || echo 0)
if [[ "$streaming_count" -ge 2 ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 7: parent module has 2+ streaming-pattern sites (got: $streaming_count)"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 7: expected 2+ streaming-pattern sites, got: $streaming_count"
fi

# --- _post_parent_task_no_markers_warning (issue-sync-lib-compose.sh) ---

assert_grep_fixed \
	"8: no-markers warning uses streaming --jq + .id select" \
	'--jq ".[] | select(.body | contains(\"${marker}\")) | .id"' \
	"$SYNC_COMPOSE"

# Test 8: verify no non-comment --slurp in sync lib.
TESTS_RUN=$((TESTS_RUN + 1))
sync_slurp=$(grep -n -- '--slurp' "$SYNC_COMPOSE" 2>/dev/null \
	| grep -vE ':\s*#' \
	| grep -vE -- '--slurpfile' \
	|| true)
if [[ -z "$sync_slurp" ]]; then
	echo "${TEST_GREEN}PASS${TEST_NC}: 9: no-markers warning has no non-comment --slurp flag"
else
	TESTS_FAILED=$((TESTS_FAILED + 1))
	echo "${TEST_RED}FAIL${TEST_NC}: 9: found non-comment --slurp in issue-sync-lib-compose.sh:"
	echo "$sync_slurp" | sed 's/^/    /'
fi

# --- Idempotency regex semantics ---
# Nudge + escalation sites use fail-closed `^[0-9]+$` (GH#20219): on API
# failure, skip the cycle rather than post. The no-markers-warning in
# issue-sync-lib.sh still uses the original `^[1-9][0-9]*$` (fail-open on
# empty — a one-shot warning is low-cost to duplicate).

assert_grep_fixed \
	"10: nudge site uses fail-closed regex (GH#20219)" \
	'[[ ! "$existing" =~ ^[0-9]+$ ]]' \
	"$PARENT_RECONCILE"

assert_grep_fixed \
	"11: no-markers-warning retains original ^[1-9] regex (fail-open)" \
	'[[ "$existing" =~ ^[1-9][0-9]*$ ]]' \
	"$SYNC_COMPOSE"

# --- Provenance ---

assert_grep_fixed \
	"12: t2572 provenance comment present in parent reconcile module" \
	't2572:' \
	"$PARENT_RECONCILE"

assert_grep_fixed \
	"13: t2572 provenance comment present in issue-sync-lib-compose.sh" \
	't2572:' \
	"$SYNC_COMPOSE"

# --- Summary ---

echo ""
echo "${TEST_BLUE}=== Results: ${TESTS_RUN} tests, ${TESTS_FAILED} failed ===${TEST_NC}"

if [[ "$TESTS_FAILED" -gt 0 ]]; then
	exit 1
fi
exit 0
