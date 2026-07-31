#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-task-complete-move.sh — regression tests for t2060
#
# Verifies that complete_task() in task-complete-helper.sh moves completed entries
# to the ## Done section instead of doing in-place [x] marking.
#
# Tests (8 edge cases):
#   1. Single-line task (no subtasks) moves from Ready to Done
#   2. Task with explicit subtask IDs (t123.1) — guard prevents completion
#   3. Task with indented subtasks (all complete) — block moves to Done
#   4. Task already in Done — idempotent (warns, exits 0)
#   5. Task in ## In Progress — also moved to Done
#   6. ## Done header missing — errors out clearly, no data loss
#   7. Multiple consecutive tasks — block boundary doesn't bleed into next entry
#   8. Completion commit keeps task proof in TODO.md and uses a guard-safe footer
#
# Strategy:
#   - Create a real git repo in a temp dir (script does git add/commit).
#   - Write fixture TODO.md files for each test case.
#   - Call task-complete-helper.sh directly (blackbox).
#   - Assert section membership and proof-log presence.

set -u

# Fixture repositories are disposable; use native Git rather than the runtime
# canonical-worktree guard shim that protects the actual source checkout.
PATH="/usr/bin:/bin:/usr/sbin:/sbin"
export PATH

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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
SCRIPTS_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)" || exit 1
HELPER="${SCRIPTS_DIR}/task-complete-helper.sh"

if [[ ! -f "$HELPER" ]]; then
	printf 'test harness cannot find helper at %s\n' "$HELPER" >&2
	exit 1
fi

TMP=$(mktemp -d -t t2060-task-complete.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Helper: set up a minimal git repo with fixture TODO.md content
# Returns the repo path in REPO_PATH variable
# -----------------------------------------------------------------------------
setup_repo() {
	local fixture_content="$1"
	local repo_name="${2:-repo}"
	local repo_dir="$TMP/$repo_name"
	mkdir -p "$repo_dir"
	printf '%s\n' "$fixture_content" >"$repo_dir/TODO.md"
	git -C "$repo_dir" init -q
	git -C "$repo_dir" config user.email "test@test.com"
	git -C "$repo_dir" config user.name "Test"
	git -C "$repo_dir" config commit.gpgsign false
	git -C "$repo_dir" config tag.gpgsign false
	git -C "$repo_dir" add TODO.md
	git -C "$repo_dir" commit -q -m "initial"
	REPO_PATH="$repo_dir"
	return 0
}

# Install a minimal commit-msg guard matching the production constraint: task
# IDs in generated completion messages must be rejected unless explicitly
# mapped. The helper must succeed without --no-verify.
install_task_id_guard_stub() {
	local repo_path="$1"
	local hooks_dir="$repo_path/test-hooks"
	mkdir -p "$hooks_dir"
	cat >"$hooks_dir/commit-msg" <<'HOOK'
#!/usr/bin/env bash
if grep -qE 't[0-9]+' "$1"; then
	exit 1
fi
exit 0
HOOK
	chmod +x "$hooks_dir/commit-msg"
	git -C "$repo_path" config core.hooksPath "$hooks_dir"
	return 0
}

# Helper: check if a task is in ## Done section
task_in_done() {
	local task_id="$1"
	local todo_file="$2"
	awk -v tid="$task_id" '
		/^## Done$/ { in_done=1; next }
		/^## /      { in_done=0; next }
		in_done && $0 ~ ("^[[:space:]]*- \\[x\\] " tid "([[:space:]]|$)") { found=1 }
		END { exit (found ? 0 : 1) }
	' "$todo_file"
	return $?
}

# Helper: check if a task is NOT in a given section
task_not_in_section() {
	local task_id="$1"
	local section_name="$2"
	local todo_file="$3"
	local found
	found=$(awk -v tid="$task_id" -v sec="$section_name" '
		$0 == "## " sec { in_sec=1; next }
		/^## /           { in_sec=0; next }
		in_sec && $0 ~ ("^[[:space:]]*- \\[" ) && $0 ~ tid { print "found" }
	' "$todo_file")
	[[ -z "$found" ]]
	return $?
}

FIXTURE_HEADER='## Format

- [ ] tXXX Description #tag

## Routines

## Ready

'

FIXTURE_SECTIONS='

## Backlog

## In Progress

## In Review

## Done

## Declined
'

printf '%sRunning task-complete-helper move-to-Done tests (t2060)%s\n' "$TEST_BLUE" "$TEST_NC"

# =============================================================================
# Test 1: Single-line task moves from Ready to Done
# =============================================================================
printf '\nTest 1: single-line task moves from Ready to Done\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t100 single line task #tag ~1h ref:GH#100 logged:2026-01-01
${FIXTURE_SECTIONS}"

setup_repo "$FIXTURE" "repo1"

"$HELPER" t100 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1

if task_in_done "t100" "$REPO_PATH/TODO.md"; then
	pass "t100 found in ## Done"
else
	fail "t100 found in ## Done" "task was not moved to Done"
fi

if grep -qE "verified:2026-01-15" "$REPO_PATH/TODO.md"; then
	pass "proof-log (verified) appended"
else
	fail "proof-log (verified) appended" "verified: not found in TODO.md"
fi

if grep -qE "completed:[0-9]{4}-[0-9]{2}-[0-9]{2}" "$REPO_PATH/TODO.md"; then
	pass "completed: timestamp appended"
else
	fail "completed: timestamp appended" "completed: not found in TODO.md"
fi

if task_not_in_section "t100" "Ready" "$REPO_PATH/TODO.md"; then
	pass "t100 no longer in ## Ready"
else
	fail "t100 no longer in ## Ready" "task still present in Ready section"
fi

# =============================================================================
# Test 2: Task with explicit open subtasks — guard blocks completion
# =============================================================================
printf '\nTest 2: explicit open subtasks block completion\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t200 parent with open subtasks #tag ~1h ref:GH#200 logged:2026-01-01
- [ ] t200.1 subtask one still open
- [ ] t200.2 subtask two still open
${FIXTURE_SECTIONS}"

setup_repo "$FIXTURE" "repo2"

if ! "$HELPER" t200 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "helper exits non-zero when open subtasks exist"
else
	fail "helper exits non-zero when open subtasks exist" "should have failed but succeeded"
fi

if ! task_in_done "t200" "$REPO_PATH/TODO.md"; then
	pass "t200 NOT moved to Done (blocked by subtasks)"
else
	fail "t200 NOT moved to Done (blocked by subtasks)" "was incorrectly moved to Done"
fi

# =============================================================================
# Test 3: Task with indented complete subtasks — block moves to Done together
# =============================================================================
printf '\nTest 3: task block with completed subtasks moves together to Done\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t300 parent with complete subtasks #tag ~1h ref:GH#300 logged:2026-01-01
  - [x] t300.1 subtask one verified:2026-01-01
  - [x] t300.2 subtask two verified:2026-01-01
${FIXTURE_SECTIONS}"

setup_repo "$FIXTURE" "repo3"

"$HELPER" t300 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1

if task_in_done "t300" "$REPO_PATH/TODO.md"; then
	pass "t300 parent found in ## Done"
else
	fail "t300 parent found in ## Done" "parent task not moved to Done"
fi

# Subtask lines should appear in the Done section (they travel with parent)
if awk '/^## Done$/{f=1; next} /^## /{f=0} f && /t300\.1/' "$REPO_PATH/TODO.md" | grep -q .; then
	pass "t300.1 subtask moved to ## Done with parent"
else
	fail "t300.1 subtask moved to ## Done with parent" "subtask not found under Done"
fi

if task_not_in_section "t300" "Ready" "$REPO_PATH/TODO.md"; then
	pass "t300 block no longer in ## Ready"
else
	fail "t300 block no longer in ## Ready" "parent still in Ready"
fi

# =============================================================================
# Test 4: Task already in Done — idempotent, warns and exits 0
# =============================================================================
printf '\nTest 4: task already in Done is idempotent\n'

# Fixture: t400 already marked [x] and living in ## Done
FIXTURE='## Format

- [ ] tXXX Description #tag

## Routines

## Ready

## Backlog

## In Progress

## In Review

## Done

- [x] t400 already done task #tag verified:2026-01-01 completed:2026-01-01

## Declined
'

setup_repo "$FIXTURE" "repo4"

if "$HELPER" t400 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "helper exits 0 when task already complete"
else
	fail "helper exits 0 when task already complete" "should succeed (idempotent)"
fi

# =============================================================================
# Test 5: Task in ## In Progress — also moved to Done
# =============================================================================
printf '\nTest 5: task in ## In Progress is moved to Done\n'

FIXTURE="${FIXTURE_HEADER}
## Backlog

## In Progress

- [ ] t500 in-progress task #tag ~1h ref:GH#500 logged:2026-01-01

## In Review

## Done

## Declined
"

setup_repo "$FIXTURE" "repo5"

"$HELPER" t500 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1

if task_in_done "t500" "$REPO_PATH/TODO.md"; then
	pass "t500 from ## In Progress found in ## Done"
else
	fail "t500 from ## In Progress found in ## Done" "task not moved to Done"
fi

if task_not_in_section "t500" "In Progress" "$REPO_PATH/TODO.md"; then
	pass "t500 no longer in ## In Progress"
else
	fail "t500 no longer in ## In Progress" "task still in In Progress"
fi

# =============================================================================
# Test 6: ## Done header missing — errors out clearly
# =============================================================================
printf '\nTest 6: ## Done header missing errors out clearly\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t600 task without done section #tag ~1h ref:GH#600 logged:2026-01-01

## Backlog

## In Progress

## In Review

## Declined
"

setup_repo "$FIXTURE" "repo6"

if ! "$HELPER" t600 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "helper exits non-zero when ## Done is missing"
else
	fail "helper exits non-zero when ## Done is missing" "should have failed"
fi

# TODO.md must be unchanged (no partial writes)
if grep -qF -- "- [ ] t600" "$REPO_PATH/TODO.md"; then
	pass "TODO.md unchanged when Done section missing (rollback works)"
else
	fail "TODO.md unchanged when Done section missing (rollback works)" \
		"TODO.md was modified despite the error"
fi

# =============================================================================
# Test 7: Multiple consecutive tasks — block boundary doesn't bleed
# =============================================================================
printf '\nTest 7: multiple consecutive tasks — block boundary stops at next entry\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t700 first task to complete #tag ~1h ref:GH#700 logged:2026-01-01
- [ ] t701 second task stays open #tag ~1h ref:GH#701 logged:2026-01-01
${FIXTURE_SECTIONS}"

setup_repo "$FIXTURE" "repo7"

"$HELPER" t700 --verified 2026-01-15 --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1

if task_in_done "t700" "$REPO_PATH/TODO.md"; then
	pass "t700 moved to ## Done"
else
	fail "t700 moved to ## Done" "t700 not found in Done"
fi

# t701 must remain open (not accidentally included in t700's block)
if grep -qE "^- \[ \] t701" "$REPO_PATH/TODO.md"; then
	pass "t701 remains open (block boundary respected)"
else
	fail "t701 remains open (block boundary respected)" \
		"t701 was incorrectly removed or modified"
fi

if ! task_in_done "t701" "$REPO_PATH/TODO.md"; then
	pass "t701 NOT in Done"
else
	fail "t701 NOT in Done" "t701 was incorrectly moved to Done"
fi

# =============================================================================
# Test 8: Completion commits use a guard-safe subject and mapped issue footer
# =============================================================================
printf '\nTest 8: completion commit uses mapped issue footer\n'

FIXTURE="${FIXTURE_HEADER}- [ ] t800 completion commit metadata #tag ~1h ref:GH#800 logged:2026-01-01
${FIXTURE_SECTIONS}"

setup_repo "$FIXTURE" "repo8"
install_task_id_guard_stub "$REPO_PATH"

if "$HELPER" t800 --verified 2026-01-15 --testing-level runtime-verified --no-push --skip-merge-check \
	--repo-path "$REPO_PATH" >/dev/null 2>&1; then
	pass "helper completes task with task-ID guard enabled"
else
	fail "helper completes task with task-ID guard enabled" "helper unexpectedly failed"
fi

commit_subject=$(git -C "$REPO_PATH" log -1 --format=%s)
commit_body=$(git -C "$REPO_PATH" log -1 --format=%b)
if [[ "$commit_subject" == "chore: mark task complete" ]]; then
	pass "completion commit subject contains no task ID"
else
	fail "completion commit subject contains no task ID" "got: $commit_subject"
fi

if [[ "$commit_body" == "For #800" ]]; then
	pass "completion commit has mapped issue footer"
else
	fail "completion commit has mapped issue footer" "got: $commit_body"
fi

if grep -qE "verified:2026-01-15 testing:runtime-verified" "$REPO_PATH/TODO.md"; then
	pass "proof metadata remains in TODO.md"
else
	fail "proof metadata remains in TODO.md" "proof metadata missing from TODO.md"
fi

# =============================================================================
# Summary
# =============================================================================
printf '\n%s----%s\n' "$TEST_BLUE" "$TEST_NC"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_NC"
	exit 0
else
	printf '%s%d of %d tests FAILED%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC"
	exit 1
fi
