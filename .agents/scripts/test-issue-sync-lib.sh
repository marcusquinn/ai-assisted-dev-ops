#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-issue-sync-lib.sh — Stub-based test harness for issue-sync-lib.sh.
#
# Model: mirrors test-privacy-guard.sh (t1969) and test-canonical-guard.sh (t1995).
# No network, no `gh` CLI dependency — `gh` is stubbed as a no-op function
# before sourcing the library. Focuses on the functions that mutate TODO.md
# content (add_gh_ref_to_todo, fix_gh_ref_in_todo, add_pr_ref_to_todo) since
# those are the ones that shipped broken on macOS (t1983 BSD awk bug) and
# carry the highest regression risk for future refactors.
#
# Tests (minimum 10):
#   1.  add_gh_ref_to_todo: plain task line — ref stamped
#   2.  add_gh_ref_to_todo: task with inline backticks — ref stamped (t1983 regression)
#   3.  add_gh_ref_to_todo: idempotent on re-run (existing ref not duplicated)
#   4.  add_gh_ref_to_todo: respects code fences (won't stamp an example task inside ```)
#   5.  add_gh_ref_to_todo: task not found in TODO.md — no change
#   6.  add_pr_ref_to_todo: stamps pr:#NNN into existing task line
#   7.  add_pr_ref_to_todo: idempotent on re-run
#   8.  strip_code_fences: strips code-fenced lines
#   9.  strip_code_fences: passes through non-fenced content
#   10. _escape_ere: escapes regex metacharacters in sub-task IDs like t001.1
#   11. t1983 explicit regression: pre-fix awk pattern WOULD fail, post-fix works
#   12. strip_code_fences: strips HTML comment regions (GH#17804 regression)
#   13. strip_code_fences: strips multi-line HTML comments and example tasks
#   14. strip_html_comments: standalone helper strips comments only
#   15. add_gh_ref_to_todo: replaces placeholder ref:none instead of appending
#
# Exit 0 = all tests pass, 1 = at least one failure.

set -u

if [[ -t 1 ]]; then
	GREEN=$'\033[0;32m'
	RED=$'\033[0;31m'
	BLUE=$'\033[0;34m'
	NC=$'\033[0m'
else
	GREEN="" RED="" BLUE="" NC=""
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
LIB="${SCRIPT_DIR}/issue-sync-lib.sh"

if [[ ! -f "$LIB" ]]; then
	printf 'test harness cannot find lib at %s\n' "$LIB" >&2
	exit 1
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Stubs: gh, log_verbose, sed_inplace fallback
# -----------------------------------------------------------------------------

# Stub gh as a no-op so any accidental invocation doesn't hit the network
gh() { return 0; }
export -f gh

# log_verbose is a logging helper defined in issue-sync-helper.sh (the main
# script). The lib references it but we source the lib standalone, so we
# provide a stub before sourcing.
log_verbose() { :; }
export -f log_verbose

# print_warning / print_info / print_error / print_success — same story.
print_warning() { :; }
print_info() { :; }
print_error() { :; }
print_success() { :; }
export -f print_warning print_info print_error print_success

# shellcheck source=issue-sync-lib.sh
# Some sourcing side-effects (shared-constants.sh resolution warnings) are
# benign; suppress them without losing the import itself.
source "$LIB" >/dev/null 2>&1 || true

printf '%sRunning issue-sync-lib tests%s\n' "$BLUE" "$NC"

# -----------------------------------------------------------------------------
# Test 1: add_gh_ref_to_todo plain line
# -----------------------------------------------------------------------------
cat >"$TMP/todo1.md" <<'EOF'
## Ready

- [ ] t9001 plain description tier:simple
EOF

add_gh_ref_to_todo "t9001" "1001" "$TMP/todo1.md"
if grep -q '^\- \[ \] t9001.*ref:GH#1001' "$TMP/todo1.md"; then
	pass "add_gh_ref_to_todo: plain task line stamped"
else
	fail "add_gh_ref_to_todo: plain task line not stamped"
	cat "$TMP/todo1.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 2: add_gh_ref_to_todo task with inline backticks (t1983 regression)
# -----------------------------------------------------------------------------
cat >"$TMP/todo2.md" <<'EOF'
## Ready

- [ ] t9002 task with `inline code` and `more backticks` in description tier:simple
EOF

add_gh_ref_to_todo "t9002" "1002" "$TMP/todo2.md"
if grep -q 'ref:GH#1002' "$TMP/todo2.md"; then
	pass "add_gh_ref_to_todo: backtick-containing line stamped (t1983 regression)"
else
	fail "add_gh_ref_to_todo: backtick line not stamped — t1983 regression!"
	cat "$TMP/todo2.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 3: add_gh_ref_to_todo idempotent on re-run
# -----------------------------------------------------------------------------
add_gh_ref_to_todo "t9001" "1001" "$TMP/todo1.md"
count=$(grep -c 'ref:GH#1001' "$TMP/todo1.md")
if [[ "$count" -eq 1 ]]; then
	pass "add_gh_ref_to_todo: idempotent on re-run (count=1)"
else
	fail "add_gh_ref_to_todo: re-run duplicated ref (count=$count)"
fi

# -----------------------------------------------------------------------------
# Test 3b: add_gh_ref_to_todo replaces ref:none placeholders (GH#26355)
# -----------------------------------------------------------------------------
cat >"$TMP/todo3b.md" <<'EOF'
## Ready

- [ ] t9003 task with placeholder ref tier:simple ref:none logged:2026-07-02
EOF

add_gh_ref_to_todo "t9003" "1003" "$TMP/todo3b.md"
if grep -q 'ref:GH#1003' "$TMP/todo3b.md" &&
	! grep -q 'ref:none' "$TMP/todo3b.md"; then
	pass "add_gh_ref_to_todo: replaces ref:none placeholder (GH#26355)"
else
	fail "add_gh_ref_to_todo: left ref:none placeholder or missed GH ref"
	cat "$TMP/todo3b.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 4: add_gh_ref_to_todo respects code fences (won't stamp an example)
# -----------------------------------------------------------------------------
cat >"$TMP/todo4.md" <<'EOF'
## Format example

```markdown
- [ ] t9004 example in code fence tier:simple
```

## Ready

- [ ] t9004 real task outside fence tier:simple
EOF

add_gh_ref_to_todo "t9004" "1004" "$TMP/todo4.md"

# Assert the REAL line got stamped, NOT the fenced example.
# The real line is outside the ``` block.
real_has_ref=$(awk '
	/^```/{f=!f; next}
	!f && /t9004.*ref:GH#1004/ {print "yes"; exit}
' "$TMP/todo4.md")

fenced_has_ref=$(awk '
	/^```/{f=!f; next}
	f && /t9004.*ref:GH#1004/ {print "yes"; exit}
' "$TMP/todo4.md")

if [[ "$real_has_ref" == "yes" && -z "$fenced_has_ref" ]]; then
	pass "add_gh_ref_to_todo: stamps real line, skips fenced example"
elif [[ "$real_has_ref" == "yes" && "$fenced_has_ref" == "yes" ]]; then
	fail "add_gh_ref_to_todo: stamped BOTH real and fenced lines (fenced should be untouched)"
else
	fail "add_gh_ref_to_todo: real line not stamped (real=$real_has_ref fenced=$fenced_has_ref)"
fi

# -----------------------------------------------------------------------------
# Test 5: add_gh_ref_to_todo task not present — no-op
# -----------------------------------------------------------------------------
cat >"$TMP/todo5.md" <<'EOF'
## Ready

- [ ] t9005 some task tier:simple
EOF
orig_content=$(cat "$TMP/todo5.md")
add_gh_ref_to_todo "t9099" "1099" "$TMP/todo5.md"
new_content=$(cat "$TMP/todo5.md")
if [[ "$orig_content" == "$new_content" ]]; then
	pass "add_gh_ref_to_todo: missing task → no-op (file unchanged)"
else
	fail "add_gh_ref_to_todo: missing task → file was modified"
fi

# -----------------------------------------------------------------------------
# Test 6: add_pr_ref_to_todo stamps pr:#NNN
# -----------------------------------------------------------------------------
cat >"$TMP/todo6.md" <<'EOF'
## Ready

- [ ] t9006 task tier:simple ref:GH#1006
EOF

add_pr_ref_to_todo "t9006" "2006" "$TMP/todo6.md"
if grep -q 'pr:#2006' "$TMP/todo6.md"; then
	pass "add_pr_ref_to_todo: pr: ref stamped"
else
	fail "add_pr_ref_to_todo: pr: ref not stamped"
	cat "$TMP/todo6.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 7: add_pr_ref_to_todo idempotent
# -----------------------------------------------------------------------------
add_pr_ref_to_todo "t9006" "2006" "$TMP/todo6.md"
count=$(grep -c 'pr:#2006' "$TMP/todo6.md")
if [[ "$count" -eq 1 ]]; then
	pass "add_pr_ref_to_todo: idempotent on re-run (count=1)"
else
	fail "add_pr_ref_to_todo: re-run duplicated ref (count=$count)"
fi

# -----------------------------------------------------------------------------
# Test 8: strip_code_fences removes fenced lines
# -----------------------------------------------------------------------------
cat >"$TMP/todo8.md" <<'EOF'
outside-line-1
```
inside-fenced-1
inside-fenced-2
```
outside-line-2
EOF

output=$(strip_code_fences <"$TMP/todo8.md")
if printf '%s\n' "$output" | grep -q 'outside-line-1' &&
	printf '%s\n' "$output" | grep -q 'outside-line-2' &&
	! printf '%s\n' "$output" | grep -q 'inside-fenced-1' &&
	! printf '%s\n' "$output" | grep -q 'inside-fenced-2'; then
	pass "strip_code_fences: fenced lines removed, outside lines preserved"
else
	fail "strip_code_fences: unexpected output"
	printf '%s\n' "$output" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 9: strip_code_fences passes through non-fenced content unchanged
# -----------------------------------------------------------------------------
cat >"$TMP/todo9.md" <<'EOF'
line1
line2
line3
EOF

orig=$(cat "$TMP/todo9.md")
output=$(strip_code_fences <"$TMP/todo9.md")
if [[ "$orig" == "$output" ]]; then
	pass "strip_code_fences: non-fenced content unchanged"
else
	fail "strip_code_fences: non-fenced content modified"
fi

# -----------------------------------------------------------------------------
# Test 10: _escape_ere escapes regex metacharacters
# -----------------------------------------------------------------------------
escaped=$(_escape_ere "t9001.1")
if [[ "$escaped" == "t9001\\.1" ]]; then
	pass "_escape_ere: escapes dot in valid sub-task ID"
else
	fail "_escape_ere: wrong escape for t9001.1 (got '$escaped')"
fi

escaped_plain=$(_escape_ere "t1990")
if [[ "$escaped_plain" == "t1990" ]]; then
	pass "_escape_ere: passes plain task ID unchanged"
else
	fail "_escape_ere: modified plain task ID (got '$escaped_plain')"
fi

# -----------------------------------------------------------------------------
# Test 11: t1983 explicit regression test — the bug was that
# `awk -v pat='...\[.\]...' '$0 ~ pat'` silently failed on BSD awk. Verify
# the current lib's pattern works by calling add_gh_ref_to_todo on a task
# line and confirming the ref was actually written (i.e. the awk line-number
# lookup succeeded).
# -----------------------------------------------------------------------------
cat >"$TMP/todo11.md" <<'EOF'
## Ready

- [ ] t9011 t1983 regression test task tier:simple
EOF

add_gh_ref_to_todo "t9011" "1983" "$TMP/todo11.md"
if grep -q 't9011.*ref:GH#1983' "$TMP/todo11.md"; then
	pass "t1983 regression: BSD awk dynamic-regex pattern works end-to-end"
else
	fail "t1983 regression: awk pattern failed — bug has regressed"
	cat "$TMP/todo11.md" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 12: strip_code_fences strips HTML-commented task examples (GH#17804)
# Regression: issue-sync-helper-push.sh extracted commented `- [ ] tNNN` lines
# from the todo-template format-example block and created spurious GitHub issues.
# -----------------------------------------------------------------------------
cat >"$TMP/todo12.md" <<'EOF'
## Ready

<!-- GH#17804: Format examples wrapped in HTML comment
- [ ] t9001 Example task description @owner ~30m
- [ ] t9002 Another example task
-->

- [ ] t9100 Real task that must survive ~15m
EOF

output12=$(strip_code_fences <"$TMP/todo12.md")
if printf '%s\n' "$output12" | grep -qE '^- \[ \] t9100 ' &&
	! printf '%s\n' "$output12" | grep -qE '^- \[ \] t900[12] '; then
	pass "strip_code_fences: HTML-commented example tasks stripped (GH#17804)"
else
	fail "strip_code_fences: HTML-commented tasks leaked through"
	printf '%s\n' "$output12" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 13: strip_code_fences handles multi-line comments and inline spans
# -----------------------------------------------------------------------------
cat >"$TMP/todo13.md" <<'EOF'
before <!-- inline comment --> middle <!-- second --> after
<!-- multi-line
- [ ] t9201 commented task
end of comment -->
keeper line
EOF

output13=$(strip_code_fences <"$TMP/todo13.md")
if printf '%s\n' "$output13" | grep -q 'before  middle  after' &&
	printf '%s\n' "$output13" | grep -q 'keeper line' &&
	! printf '%s\n' "$output13" | grep -q 't9201'; then
	pass "strip_code_fences: multi-line + inline HTML comments handled"
else
	fail "strip_code_fences: comment span handling incorrect"
	printf '%s\n' "$output13" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Test 14: strip_html_comments standalone helper
# -----------------------------------------------------------------------------
cat >"$TMP/todo14.md" <<'EOF'
keep <!-- drop --> keep
```
fenced content stays
```
<!-- whole-line comment -->
final
EOF

output14=$(strip_html_comments <"$TMP/todo14.md")
if printf '%s\n' "$output14" | grep -q 'keep  keep' &&
	printf '%s\n' "$output14" | grep -q 'fenced content stays' &&
	printf '%s\n' "$output14" | grep -q 'final' &&
	! printf '%s\n' "$output14" | grep -q 'whole-line comment'; then
	pass "strip_html_comments: removes comments, leaves fences intact"
else
	fail "strip_html_comments: unexpected output"
	printf '%s\n' "$output14" | sed 's/^/     /'
fi

# -----------------------------------------------------------------------------
# Task identity codec integration
# -----------------------------------------------------------------------------
ORIGIN_ID="o01j2abc3def4gh5jkm6npq7rst"
NAMESPACED_ID="t${ORIGIN_ID}-42.3"
parsed_line=$(parse_task_line "- [ ] ${NAMESPACED_ID} namespaced task blocked-by:t7,${NAMESPACED_ID} blocks:t9.1 ref:GH#100")
if printf '%s\n' "$parsed_line" | grep -qx "task_id=${NAMESPACED_ID}" &&
	printf '%s\n' "$parsed_line" | grep -qx "blocked_by=t7,${NAMESPACED_ID}" &&
	printf '%s\n' "$parsed_line" | grep -qx 'blocks=t9.1'; then
	pass "parse_task_line: preserves complete namespaced dependency IDs"
else
	fail "parse_task_line: truncated namespaced task or dependency ID"
fi

if parse_task_line '- [ ] t01 malformed task mentioning t7 later' >/dev/null 2>&1; then
	fail "parse_task_line: accepted malformed checkbox ID via later valid token"
else
	pass "parse_task_line: validates the canonical checkbox position"
fi

if parse_task_line '- [ ] t7 valid task blocked-by:t01' >/dev/null 2>&1; then
	fail "parse_task_line: accepted malformed dependency"
else
	pass "parse_task_line: malformed dependency fails closed"
fi

parsed_parent=$(parse_task_line '- [ ] t7 child task parent:t6 ref:GH#100')
if printf '%s\n' "$parsed_parent" | grep -qx 'description=child task' &&
	printf '%s\n' "$parsed_parent" | grep -qx 'parent=t6'; then
	pass "parse_task_line: preserves singular parent hierarchy metadata"
else
	fail "parse_task_line: omitted parent hierarchy metadata"
fi

if parse_task_line '- [ ] t7 malformed parent parent:t01' >/dev/null 2>&1; then
	fail "parse_task_line: accepted malformed parent metadata"
else
	pass "parse_task_line: malformed parent fails closed"
fi

if parse_task_line '- [ ] t7 conflicting parents parent:t5 parent:t6' >/dev/null 2>&1; then
	fail "parse_task_line: accepted multiple parent declarations"
else
	pass "parse_task_line: multiple parent declarations fail closed"
fi

parsed_tags=$(parse_task_line '- [ ] t7 preserve labels #bug #release-blocker #priority:high tier:standard')
if printf '%s\n' "$parsed_tags" | grep -qx 'tags=#bug,#release-blocker,#priority:high'; then
	pass "parse_task_line: preserves simple, hyphenated, and colon-qualified tags"
else
	fail "parse_task_line: truncated a colon-qualified tag or changed existing tags"
fi

mapped_labels=$(map_tags_to_labels "$(printf '%s\n' "$parsed_tags" | sed -n 's/^tags=//p')")
if [[ "$mapped_labels" == "bug,priority:high,release-blocker" ]] &&
	! printf '%s\n' "$mapped_labels" | tr ',' '\n' | grep -qx 'priority'; then
	pass "map_tags_to_labels: preserves priority:high without a bare priority label"
else
	fail "map_tags_to_labels: changed or truncated priority:high"
fi

for priority in critical high medium low; do
	parsed_priority=$(parse_task_line "- [ ] t7 preserve priority #priority:${priority} tier:standard")
	if printf '%s\n' "$parsed_priority" | grep -qx "tags=#priority:${priority}" &&
		[[ "$(map_tags_to_labels "#priority:${priority}")" == "priority:${priority}" ]]; then
		pass "priority tags: preserves priority:${priority} exactly"
	else
		fail "priority tags: changed or truncated priority:${priority}"
	fi
done

# -----------------------------------------------------------------------------
# extract_task_block behavior and large-file process regression (GH#28791)
# -----------------------------------------------------------------------------
cat >"$TMP/todo-extract.md" <<EOF
- [ ] t7 open parent
  - [x] t7.1 completed child
    - Notes: nested child evidence
  - Notes: parent evidence
- [x] ${NAMESPACED_ID} completed namespaced parent
  - Notes: namespaced evidence
- [-] t9 declined task
## Boundary
EOF

expected_t7=$'- [ ] t7 open parent\n  - [x] t7.1 completed child\n    - Notes: nested child evidence\n  - Notes: parent evidence'
actual_t7=$(extract_task_block "t7" "$TMP/todo-extract.md")
if [[ "$actual_t7" == "$expected_t7" ]]; then
	pass "extract_task_block: preserves nested subtasks and notes exactly"
else
	fail "extract_task_block: changed nested block output"
fi

expected_namespaced="- [x] ${NAMESPACED_ID} completed namespaced parent"$'\n'"  - Notes: namespaced evidence"
actual_namespaced=$(extract_task_block "$NAMESPACED_ID" "$TMP/todo-extract.md")
if [[ "$actual_namespaced" == "$expected_namespaced" ]]; then
	pass "extract_task_block: matches completed origin-namespaced IDs literally"
else
	fail "extract_task_block: failed origin-namespaced lookup"
fi

if [[ "$(extract_task_block "t9" "$TMP/todo-extract.md")" == "- [-] t9 declined task" ]]; then
	pass "extract_task_block: preserves declined task status and heading boundary"
else
	fail "extract_task_block: changed declined task or heading boundary behavior"
fi

if [[ -z "$(extract_task_block "t8" "$TMP/todo-extract.md")" ]]; then
	pass "extract_task_block: missing canonical ID returns an empty block"
else
	fail "extract_task_block: missing canonical ID returned content"
fi

if extract_task_block "t01" "$TMP/todo-extract.md" >/dev/null 2>&1; then
	fail "extract_task_block: accepted malformed task ID"
else
	pass "extract_task_block: malformed task ID fails closed"
fi

large_todo="$TMP/todo-extract-large.md"
{
	i=1
	while [[ $i -le 4500 ]]; do
		printf -- '- [ ] t%d generated task %d\n' "$i" "$i"
		i=$((i + 1))
	done
} >"$large_todo"

GREP_CALL_LOG="$TMP/extract-task-block-grep-calls.log"
export GREP_CALL_LOG
grep() {
	local grep_status=0
	printf 'grep called\n' >>"$GREP_CALL_LOG"
	command grep "$@" || grep_status=$?
	return "$grep_status"
}
export -f grep
extract_started=$SECONDS
large_result=$(extract_task_block "t4500" "$large_todo")
extract_elapsed=$((SECONDS - extract_started))
unset -f grep

if [[ "$large_result" == "- [ ] t4500 generated task 4500" && ! -s "$GREP_CALL_LOG" && $extract_elapsed -lt 5 ]]; then
	pass "extract_task_block: late lookup avoids per-line grep processes"
else
	fail "extract_task_block: late lookup output/process/time regression (elapsed=${extract_elapsed}s)"
fi

mkdir -p "$TMP/project/todo"
cat >"$TMP/project/todo/PLANS.md" <<'EOF'
### Root plan

**TODO:** t7

#### Purpose
Root plan body.
EOF
plan_result=$(find_plan_by_task_id 't7.2.3' "$TMP/project")
if printf '%s\n' "$plan_result" | grep -q 'Root plan'; then
	pass "find_plan_by_task_id: walks every ancestor to the root"
else
	fail "find_plan_by_task_id: failed deep hierarchy root lookup"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d test(s) passed%s\n' "$GREEN" "$TESTS_RUN" "$NC"
	exit 0
fi
printf '%s%d of %d test(s) failed%s\n' "$RED" "$TESTS_FAILED" "$TESTS_RUN" "$NC"
exit 1
