#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-stale-recovery-age-floor.sh — t2153 regression guard.
#
# Asserts that `_is_stale_assignment` does NOT mark a freshly-created issue
# as stale, even when:
#   - it has a blocking assignee (auto-assigned at creation time)
#   - it has zero comments (no dispatch claim, no activity yet)
#
# Production failure (#19414, GH#19424):
#   23:09:29Z — Issue created, marcusquinn auto-assigned via issue-sync
#               from a TODO entry. Labels: origin:interactive + status:queued.
#   23:14:22Z — stale-recovery-tick:1 posted (4 min 53 s after creation).
#   23:14:30Z — WORKER_SUPERSEDED comment, reason "no dispatch claim comment
#               found, no recent activity (threshold=7200s, interactive=true)".
#   The 7200s interactive threshold was NEVER compared against issue age —
#   it was compared against (non-existent) comment timestamps. Both
#   last_dispatch_ts and last_activity_ts were empty, the inner activity-age
#   check was skipped, control fell through to _recover_stale_assignment.
#
# Fix (t2153): _resolve_stale_threshold also returns issue.createdAt;
# _is_stale_assignment short-circuits with "not stale" when
# (now - createdAt) < effective_threshold.
#
# Tests use the public is-assigned subcommand of dispatch-dedup-helper.sh
# — the actual production call path. Stubs follow the same pattern as
# test-dispatch-dedup-fail-closed.sh.
#
# Failure history motivating this test: GH#19414 / GH#19424 (t2153).
# Cross-references: t2132 (interactive threshold + sentinel pattern,
# PR #19237) addressed staleness during ACTIVE interactive sessions but
# did not cover the brand-new-issue case where no comments exist at all.

set -uo pipefail

TEST_SCRIPTS_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEST_RED=$'\033[0;31m'
TEST_GREEN=$'\033[0;32m'
TEST_RESET=$'\033[0m'

TESTS_RUN=0
TESTS_FAILED=0

print_result() {
	local name="$1" rc="$2" extra="${3:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$rc" -eq 0 ]]; then
		printf '%sPASS%s %s\n' "$TEST_GREEN" "$TEST_RESET" "$name"
	else
		printf '%sFAIL%s %s %s\n' "$TEST_RED" "$TEST_RESET" "$name" "$extra"
		TESTS_FAILED=$((TESTS_FAILED + 1))
	fi
}

# Sandbox HOME so sourcing is side-effect-free
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor"

STUB_DIR="${TEST_ROOT}/bin"
mkdir -p "$STUB_DIR"
GH_CALLS_FILE="${TEST_ROOT}/gh_calls.log"

#######################################
# iso_minus_seconds: portable "<N> seconds ago" in ISO 8601 UTC.
# Bash 3.2 + macOS / Linux both supported. Falls back to "1970-01-01T00:00:00Z"
# on parse failure (defensive — never observed in practice).
#######################################
iso_minus_seconds() {
	local seconds="$1"
	if [[ "$(uname)" == "Darwin" ]]; then
		TZ=UTC date -u -v-"${seconds}"S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
			printf '1970-01-01T00:00:00Z'
	else
		TZ=UTC date -u -d "${seconds} seconds ago" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null ||
			printf '1970-01-01T00:00:00Z'
	fi
}

#######################################
# write_stub_gh_age_floor: gh stub for the age-floor scenarios.
# Records every call to GH_CALLS_FILE for assertion debugging.
#
#   - `gh issue view ... --json ...` returns the supplied issue payload.
#     The same payload satisfies both the main is_assigned call (which
#     consumes assignees/labels/state) and _resolve_stale_threshold
#     (which consumes labels/createdAt). Extra fields are harmless —
#     downstream jq filters pick only what they look up.
#   - `gh api repos/.../comments` returns the supplied comments JSON
#     (default: empty array — no comments yet, the bug scenario).
#     If the call includes `length` in --jq (count_ticks path), returns 0.
#   - All other `gh` calls (issue edit, issue comment) silently succeed.
#
# Args:
#   $1 = issue payload JSON (single-quoted in heredoc)
#   $2 = comments payload JSON (default '[]')
#######################################
write_stub_gh_age_floor() {
	local payload="$1"
	local comments_payload="${2:-[]}"
	: >"$GH_CALLS_FILE"
	cat >"${STUB_DIR}/gh" <<STUBEOF
#!/usr/bin/env bash
# Stub gh for test-stale-recovery-age-floor.sh
printf '%s\n' "\$*" >> "${GH_CALLS_FILE}"

# gh issue view ... → return canned issue payload
if [[ "\$1" == "issue" && "\$2" == "view" ]]; then
	printf '%s\n' '${payload}'
	exit 0
fi

# gh api .../comments — two shapes:
#   1. With --jq containing 'length' → integer count (ticks counter)
#   2. Otherwise → comments array
if [[ "\$1" == "api" && "\$2" == *"/comments" ]]; then
	if [[ "\$*" == *"length"* ]]; then
		printf '0\n'
	else
		printf '%s\n' '${comments_payload}'
	fi
	exit 0
fi

# gh pr list → empty (no open PR for stale recovery to detect)
if [[ "\$1" == "pr" && "\$2" == "list" ]]; then
	printf '[]\n'
	exit 0
fi

# gh issue edit, gh issue comment → silent success
if [[ "\$1" == "issue" ]]; then
	exit 0
fi
exit 0
STUBEOF
	chmod +x "${STUB_DIR}/gh"
	return 0
}

OLD_PATH="$PATH"
export PATH="${STUB_DIR}:${OLD_PATH}"

#######################################
# run_is_assigned: invoke the public is-assigned subcommand. Captures
# stdout into $output and exit code into $rc.
#######################################
output=""
rc=0
run_is_assigned() {
	local issue="$1" repo="$2" self="${3:-self-login}"
	output=$("${TEST_SCRIPTS_DIR}/dispatch-dedup-helper.sh" is-assigned "$issue" "$repo" "$self" 2>/dev/null)
	rc=$?
	return 0
}

# =============================================================================
# Test 1 — Fresh interactive issue (60 s old) → NOT stale, ASSIGNED, block.
# This is the production failure mode (#19414 / GH#19424).
# Without the t2153 fix: comments=[] → stale-recovery fires → exit 1 (allow).
# With the t2153 fix: age-floor short-circuits → ASSIGNED, exit 0 (block).
# =============================================================================
fresh_iso=$(iso_minus_seconds 60)
write_stub_gh_age_floor "{\"state\":\"OPEN\",\"assignees\":[{\"login\":\"other-runner\"}],\"labels\":[{\"name\":\"origin:interactive\"},{\"name\":\"tier:standard\"}],\"createdAt\":\"${fresh_iso}\"}"
run_is_assigned 99701 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"ASSIGNED"* && "$output" != *"WORKER_SUPERSEDED"* ]]; then
	print_result "Fresh interactive issue (60s old) → ASSIGNED, NOT stale-recovered" 0
else
	print_result "Fresh interactive issue (60s old) → ASSIGNED, NOT stale-recovered" 1 \
		"(rc=$rc output='$output')"
fi

# Negative assertion — no stale-recovery comment was attempted.
if ! grep -q "WORKER_SUPERSEDED" "$GH_CALLS_FILE" 2>/dev/null; then
	print_result "Fresh interactive issue: no WORKER_SUPERSEDED comment posted" 0
else
	print_result "Fresh interactive issue: no WORKER_SUPERSEDED comment posted" 1 \
		"(gh calls: $(head -10 "$GH_CALLS_FILE"))"
fi

# =============================================================================
# Test 2 — Old interactive issue (3 h old, well past 7200s threshold) →
#         existing stale-recovery still fires → exit 1 (allow dispatch).
# Regression guard: the age-floor must not protect issues older than the
# threshold itself. Without this assertion, a too-aggressive guard could
# silently disable stale-recovery entirely.
# =============================================================================
old_iso=$(iso_minus_seconds 10800) # 3 hours
write_stub_gh_age_floor "{\"state\":\"OPEN\",\"assignees\":[{\"login\":\"other-runner\"}],\"labels\":[{\"name\":\"origin:interactive\"},{\"name\":\"tier:standard\"}],\"createdAt\":\"${old_iso}\"}"
run_is_assigned 99702 "owner/repo"
if [[ "$rc" -eq 1 && "$output" != *"ASSIGNED"* ]]; then
	print_result "Old interactive issue (3h old, no comments) → stale-recovered, exit 1 (allow dispatch)" 0
else
	print_result "Old interactive issue (3h old, no comments) → stale-recovered, exit 1 (allow dispatch)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Test 3 — Fresh worker-tier issue (60 s old, threshold 600s) → NOT stale.
# The age-floor must apply at every threshold tier, not just interactive.
# =============================================================================
fresh_iso2=$(iso_minus_seconds 60)
write_stub_gh_age_floor "{\"state\":\"OPEN\",\"assignees\":[{\"login\":\"other-runner\"}],\"labels\":[{\"name\":\"tier:standard\"}],\"createdAt\":\"${fresh_iso2}\"}"
run_is_assigned 99703 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"ASSIGNED"* ]]; then
	print_result "Fresh worker-tier issue (60s old, threshold 600s) → ASSIGNED, NOT stale-recovered" 0
else
	print_result "Fresh worker-tier issue (60s old, threshold 600s) → ASSIGNED, NOT stale-recovered" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Test 4 — Old worker issue (15 min old, past 600s threshold) → stale-recovered.
# Companion to Test 2: ensure the age-floor doesn't over-protect at the
# worker threshold either.
# =============================================================================
old_iso2=$(iso_minus_seconds 900) # 15 minutes
write_stub_gh_age_floor "{\"state\":\"OPEN\",\"assignees\":[{\"login\":\"other-runner\"}],\"labels\":[{\"name\":\"tier:standard\"}],\"createdAt\":\"${old_iso2}\"}"
run_is_assigned 99704 "owner/repo"
if [[ "$rc" -eq 1 && "$output" != *"ASSIGNED"* ]]; then
	print_result "Old worker-tier issue (15min old, no comments) → stale-recovered, exit 1 (allow dispatch)" 0
else
	print_result "Old worker-tier issue (15min old, no comments) → stale-recovered, exit 1 (allow dispatch)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Test 5 — Missing createdAt (defensive) → fall through to existing logic.
# If createdAt is absent (gh schema drift, partial response), the age-floor
# guard must NOT short-circuit — it must let the comment-based logic decide.
# Worker tier + no comments + no createdAt → falls through to stale recovery.
# =============================================================================
write_stub_gh_age_floor '{"state":"OPEN","assignees":[{"login":"other-runner"}],"labels":[{"name":"tier:standard"}]}'
run_is_assigned 99705 "owner/repo"
if [[ "$rc" -eq 1 && "$output" != *"ASSIGNED"* ]]; then
	print_result "Missing createdAt → falls through to existing logic (stale-recovered)" 0
else
	print_result "Missing createdAt → falls through to existing logic (stale-recovered)" 1 \
		"(rc=$rc output='$output')"
fi

# =============================================================================
# Test 6 — Immutable worker provenance plus a live interactive claim uses the
# interactive threshold. The claim is 13 minutes old: stale at 600 seconds but
# live at 7200 seconds. This reproduces the #28591 ownership shape.
# =============================================================================
old_issue_iso=$(iso_minus_seconds 10800)
interactive_claim_iso=$(iso_minus_seconds 780)
live_interactive_comments="[[{\"created_at\":\"${interactive_claim_iso}\",\"user\":{\"login\":\"other-runner\"},\"body\":\"> Interactive session claimed by @other-runner in linked-worktree.\"}]]"
write_stub_gh_age_floor "{\"state\":\"OPEN\",\"assignees\":[{\"login\":\"other-runner\"}],\"labels\":[{\"name\":\"origin:worker\"},{\"name\":\"auto-dispatch\"},{\"name\":\"status:in-review\"}],\"createdAt\":\"${old_issue_iso}\",\"updatedAt\":\"${old_issue_iso}\"}" "$live_interactive_comments"
run_is_assigned 99706 "owner/repo"
if [[ "$rc" -eq 0 && "$output" == *"ASSIGNED"* && "$output" != *"WORKER_SUPERSEDED"* ]]; then
	print_result "origin:worker live interactive claim beyond 600s remains protected" 0
else
	print_result "origin:worker live interactive claim beyond 600s remains protected" 1 \
		"(rc=$rc output='$output')"
fi

# The comment alone is not a lock: without compatible in-review state, worker
# provenance retains the 600-second policy and stale recovery still proceeds.
write_stub_gh_age_floor "{\"state\":\"OPEN\",\"assignees\":[{\"login\":\"other-runner\"}],\"labels\":[{\"name\":\"origin:worker\"},{\"name\":\"auto-dispatch\"},{\"name\":\"status:available\"}],\"createdAt\":\"${old_issue_iso}\",\"updatedAt\":\"${old_issue_iso}\"}" "$live_interactive_comments"
run_is_assigned 99707 "owner/repo"
if [[ "$rc" -eq 1 && "$output" != *"ASSIGNED"* ]]; then
	print_result "interactive comment without live ownership retains worker stale policy" 0
else
	print_result "interactive comment without live ownership retains worker stale policy" 1 \
		"(rc=$rc output='$output')"
fi

export PATH="$OLD_PATH"

# =============================================================================
# Summary
# =============================================================================
echo
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s\n' "$TEST_GREEN" "$TESTS_RUN" "$TEST_RESET"
	exit 0
else
	printf '%s%d / %d tests failed%s\n' "$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_RESET"
	exit 1
fi
