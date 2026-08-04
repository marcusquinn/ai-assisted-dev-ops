#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-dirty-pr-sweep.sh — Regression tests for pulse-dirty-pr-sweep.sh
# (t2350 / GH#19948).
#
# Covers the three classification paths and the cross-cutting safety gates:
#
#   1. Rebase path   — young PR (< 48h), maintainer-owned, only TODO.md
#                      conflicts → classify returns "rebase|todo-only-conflict".
#   2. Close path    — old PR (> 7d), idle (> 3d), no opt-out label
#                      → classify returns "close|stale-and-idle".
#   3. Conflict path — young worker PR with non-TODO conflicts → classify
#                      returns "conflict|..." (never rebase or close).
#   4. Opt-out       — `do-not-close` label forces notify, never close.
#   5. Opt-out       — `parent-task` label forces notify, never close.
#   6. Opt-out       — `origin:interactive` label forces notify, never close.
#   7. Idempotency   — a recorded action within the cooldown window is
#                      honoured (classify still returns a decision, but the
#                      action helper short-circuits on _dps_recently_actioned).
#   8. Dry-run       — DRY_RUN=1 never calls `gh pr close` or `git rebase`.
#   9. Interval gate — sweep returns early when DIRTY_PR_SWEEP_LAST_RUN is
#                      within DIRTY_PR_SWEEP_INTERVAL.
#
# Most classifier paths are pure given their JSON input. The worker-backed
# origin:interactive path fetches the linked issue labels, so tests stub `gh`
# or disable that check by env. No real PRs are touched.

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
	return 0
}

# Sandbox HOME + fake repos.json so sourcing is side-effect free.
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT
export HOME="${TEST_ROOT}/home"
mkdir -p "${HOME}/.aidevops/logs" "${HOME}/.aidevops/.agent-workspace/supervisor" \
	"${HOME}/.config/aidevops"
# Minimal repos.json (empty initialized_repos array)
printf '%s' '{"initialized_repos":[]}' >"${HOME}/.config/aidevops/repos.json"

# Point state + interval files at the sandbox so classification tests never
# touch real state.
export DIRTY_PR_SWEEP_LAST_RUN="${HOME}/.aidevops/logs/dirty-pr-sweep-last-run"
export DIRTY_PR_SWEEP_STATE_FILE="${HOME}/.aidevops/.agent-workspace/supervisor/dirty-pr-sweep-state.json"
export AIDEVOPS_DIRTY_PR_WORKER_BACKED_CHECK=0

# Source the module. shellcheck disable=SC1091
# shellcheck source=../pulse-dirty-pr-sweep.sh
source "${TEST_SCRIPTS_DIR}/pulse-dirty-pr-sweep.sh" || {
	echo "FAIL: sourcing pulse-dirty-pr-sweep.sh failed" >&2
	exit 1
}

# Helper: make a synthetic PR JSON object matching the fields
# _dirty_pr_classify reads from `gh pr list`.
# Args: $1=number $2=mss $3=createdAt $4=updatedAt $5=author $6=headRef
#       $7=labels_json (e.g. '["origin:worker"]' or '[]')
#       $8=body (optional; defaults to empty string)
mkpr() {
	local n="$1" mss="$2" created="$3" updated="$4" author="$5" head="$6" labels_json="$7"
	local body="${8:-}"
	local tmpfile
	tmpfile=$(mktemp)
	local labels_array
	labels_array=$(printf '%s' "$labels_json" | jq '[.[] | {name: .}]')
	jq -n \
		--argjson n "$n" \
		--arg mss "$mss" \
		--arg created "$created" \
		--arg updated "$updated" \
		--arg author "$author" \
		--arg head "$head" \
		--argjson labels "$labels_array" \
		--arg body "$body" \
		'{number:$n, mergeStateStatus:$mss, createdAt:$created, updatedAt:$updated,
			author:{login:$author}, labels:$labels, headRefName:$head, baseRefName:"main", body:$body}' \
		>"$tmpfile"
	cat "$tmpfile"
	rm -f "$tmpfile"
	return 0
}

# Helper: ISO timestamp for "N seconds ago".
iso_n_seconds_ago() {
	local n="$1"
	local target
	target=$(($(date +%s) - n))
	if date -u -d "@$target" '+%Y-%m-%dT%H:%M:%SZ' >/dev/null 2>&1; then
		date -u -d "@$target" '+%Y-%m-%dT%H:%M:%SZ'
	else
		# macOS BSD date
		date -u -r "$target" '+%Y-%m-%dT%H:%M:%SZ'
	fi
	return 0
}

# =============================================================================
# Test 1: rebase path — young PR, maintainer-owned, only TODO.md conflicts
# =============================================================================

# Build a minimal ephemeral git repo where ONLY TODO.md conflicts between
# a feature branch and origin/main.
REPO_ROOT="${TEST_ROOT}/repo"
setup_repo_with_todo_conflict() {
	rm -rf "$REPO_ROOT"
	mkdir -p "$REPO_ROOT"
	(
		cd "$REPO_ROOT" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "tester"
		git config commit.gpgsign false
		printf '# base\n' >TODO.md
		printf '# base\n' >unrelated.md
		git add -A && git commit -qm "base"
		# Advance "main" with a new TODO.md line.
		printf '# base\nmain-side\n' >TODO.md
		git add TODO.md && git commit -qm "main: add main-side"
		git update-ref refs/remotes/origin/main main
		# Set origin/HEAD so _dps_get_default_branch can resolve "main".
		git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
		# Feature branch diverges from the base commit.
		git checkout -qb feature/todo-conflict HEAD~1
		printf '# base\nfeature-side\n' >TODO.md
		git add TODO.md && git commit -qm "feature: add feature-side"
	)
	return 0
}

setup_repo_with_todo_conflict
PR_YOUNG_WORKER=$(mkpr 100 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"marcusquinn" \
	"feature/todo-conflict" \
	'["origin:worker"]')

decision=$(_dirty_pr_classify "$PR_YOUNG_WORKER" "test/repo" "$REPO_ROOT" "marcusquinn")
case "$decision" in
	rebase\|*) print_result "rebase path: young + worker-origin + TODO-only → rebase" 0 ;;
	*) print_result "rebase path: young + worker-origin + TODO-only → rebase" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 2: close path — stale + idle + no opt-out
# =============================================================================

PR_STALE=$(mkpr 200 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"some-external-user" \
	"feature/old" \
	'[]')

decision=$(_dirty_pr_classify "$PR_STALE" "test/repo" "" "marcusquinn")
case "$decision" in
	close\|*) print_result "close path: >7d old + >3d idle → close" 0 ;;
	*) print_result "close path: >7d old + >3d idle → close" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 3: notify path — non-TODO conflicts
# =============================================================================

# Build a repo where a non-TODO file conflicts
setup_repo_with_nontodo_conflict() {
	rm -rf "$REPO_ROOT"
	mkdir -p "$REPO_ROOT"
	(
		cd "$REPO_ROOT" || exit 1
		git init -q -b main
		git config user.email "test@example.com"
		git config user.name "tester"
		git config commit.gpgsign false
		printf 'base-code\n' >src.sh
		git add -A && git commit -qm "base"
		printf 'main-side-code\n' >src.sh
		git add src.sh && git commit -qm "main: modify"
		git update-ref refs/remotes/origin/main main
		# Set origin/HEAD so _dps_get_default_branch can resolve "main".
		git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
		git checkout -qb feature/code-conflict HEAD~1
		printf 'feature-side-code\n' >src.sh
		git add src.sh && git commit -qm "feature: modify"
	)
	return 0
}

setup_repo_with_nontodo_conflict
PR_CODE_CONFLICT=$(mkpr 300 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"marcusquinn" \
	"feature/code-conflict" \
	'["origin:worker"]')

decision=$(_dirty_pr_classify "$PR_CODE_CONFLICT" "test/repo" "$REPO_ROOT" "marcusquinn")
case "$decision" in
	conflict\|worker-backed-semantic-conflict) print_result "worker path: non-TODO conflicts → route conflict feedback" 0 ;;
	rebase\|*) print_result "worker path: non-TODO conflicts → route conflict feedback" 1 "got: $decision (must NOT auto-rebase)" ;;
	*) print_result "worker path: non-TODO conflicts → route conflict feedback" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 4: do-not-close opt-out
# =============================================================================

PR_OPTOUT=$(mkpr 400 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/foo" \
	'["do-not-close"]')

decision=$(_dirty_pr_classify "$PR_OPTOUT" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|do-not-close-label) print_result "opt-out: do-not-close label → notify" 0 ;;
	close\|*) print_result "opt-out: do-not-close label → notify" 1 "got: $decision (should NOT be close)" ;;
	*) print_result "opt-out: do-not-close label → notify" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 5: parent-task opt-out
# =============================================================================

PR_PARENT=$(mkpr 500 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"marcusquinn" \
	"feature/bar" \
	'["origin:worker", "parent-task"]')

decision=$(_dirty_pr_classify "$PR_PARENT" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|parent-task-label) print_result "opt-out: parent-task label → notify (no rebase)" 0 ;;
	rebase\|*) print_result "opt-out: parent-task label → notify (no rebase)" 1 "got: $decision (must NOT rebase)" ;;
	close\|*) print_result "opt-out: parent-task label → notify (no rebase)" 1 "got: $decision (must NOT close)" ;;
	*) print_result "opt-out: parent-task label → notify (no rebase)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6: origin:interactive WITHOUT issue reference → notify (orphan)
#         After t2708 the label alone no longer forces notify — the body must
#         also lack any recognised issue reference.
# =============================================================================

PR_INTERACTIVE_ORPHAN=$(mkpr 600 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/baz" \
	'["origin:interactive"]' \
	"Some PR description with no issue reference at all.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_ORPHAN" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|origin-interactive-orphan) print_result "t2708: origin:interactive orphan → notify with orphan reason" 0 ;;
	close\|*) print_result "t2708: origin:interactive orphan → notify with orphan reason" 1 "got: $decision (must NOT close when body has no ref)" ;;
	*) print_result "t2708: origin:interactive orphan → notify with orphan reason" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6a: origin:interactive WITH `Resolves #NNN` + 10d old → notify
#          (t2711 Q2) Within the 14d extended window, referenced interactive
#          PRs get notify, not close.
# =============================================================================

PR_INTERACTIVE_RESOLVES=$(mkpr 610 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/baz-resolves" \
	'["origin:interactive"]' \
	"This PR implements the fix. Resolves #12345.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_RESOLVES" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|origin-interactive-referenced-within-extended-window) print_result "t2711: origin:interactive + Resolves #NNN + 10d → notify (within 14d window)" 0 ;;
	close\|*) print_result "t2711: origin:interactive + Resolves #NNN + 10d → notify (within 14d window)" 1 "got: $decision (must NOT close within 14d window)" ;;
	*) print_result "t2711: origin:interactive + Resolves #NNN + 10d → notify (within 14d window)" 1 "got: $decision" ;;
esac

if _dps_pr_body_has_issue_reference "This PR fixes the problem. Resolves #26346."; then
	print_result "t2711: closing keyword reference parser recognises Resolves #NNN" 0
else
	print_result "t2711: closing keyword reference parser recognises Resolves #NNN" 1 "Resolves #NNN was not detected"
fi

# =============================================================================
# Test 6a-worker-backed: origin:interactive PR against an origin:worker issue
#                       routes semantic conflicts for worker redispatch.
# =============================================================================

STUB_DIR_WORKER_BACKED="${TEST_ROOT}/stubs-worker-backed"
mkdir -p "$STUB_DIR_WORKER_BACKED"
cat >"${STUB_DIR_WORKER_BACKED}/gh" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "issue" && "$2" == "view" ]]; then
	printf '%s\n' 'origin:worker'
	printf '%s\n' 'auto-dispatch'
	printf '%s\n' 'function-complexity-debt'
	exit 0
fi
exit 1
STUB
chmod +x "${STUB_DIR_WORKER_BACKED}/gh"
PATH_BEFORE_WORKER_BACKED="$PATH"
export PATH="${STUB_DIR_WORKER_BACKED}:${PATH}"
export AIDEVOPS_DIRTY_PR_WORKER_BACKED_CHECK=1

PR_INTERACTIVE_WORKER_BACKED=$(mkpr 611 "DIRTY" \
	"$(iso_n_seconds_ago 3600)" \
	"$(iso_n_seconds_ago 1800)" \
	"marcusquinn" \
	"feature/baz-worker-backed" \
	'["origin:interactive"]' \
	"This PR implements the fix. Resolves #26346.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_WORKER_BACKED" "test/repo" "" "other-runner")
case "$decision" in
	conflict\|worker-backed-semantic-conflict) print_result "GH#26346: origin:interactive PR linked to worker issue → conflict routing" 0 ;;
	notify\|origin-interactive-referenced-within-extended-window) print_result "GH#26346: origin:interactive PR linked to worker issue → conflict routing" 1 "got: $decision (must route for redispatch, not only notify)" ;;
	*) print_result "GH#26346: origin:interactive PR linked to worker issue → conflict routing" 1 "got: $decision" ;;
esac

export AIDEVOPS_DIRTY_PR_WORKER_BACKED_CHECK=0
export PATH="$PATH_BEFORE_WORKER_BACKED"

# =============================================================================
# Test 6b: origin:interactive WITH `For #NNN` + 10d old → notify
#          (t2711 Q2) Within the 14d extended window. Planning-PR pattern from
#          AGENTS.md "Parent-task PR keyword rule".
# =============================================================================

PR_INTERACTIVE_FOR=$(mkpr 620 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/baz-for" \
	'["origin:interactive"]' \
	"Phase 1 implementation. For #12345.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_FOR" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|origin-interactive-referenced-within-extended-window) print_result "t2711: origin:interactive + For #NNN + 10d → notify (within 14d window)" 0 ;;
	close\|*) print_result "t2711: origin:interactive + For #NNN + 10d → notify (within 14d window)" 1 "got: $decision (must NOT close within 14d window)" ;;
	*) print_result "t2711: origin:interactive + For #NNN + 10d → notify (within 14d window)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6c: origin:interactive WITH `Ref #NNN` + 10d old → notify
#          (t2711 Q2) Within the 14d extended window.
# =============================================================================

PR_INTERACTIVE_REF=$(mkpr 630 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/baz-ref" \
	'["origin:interactive"]' \
	"Investigation notes. Ref #12345.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_REF" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|origin-interactive-referenced-within-extended-window) print_result "t2711: origin:interactive + Ref #NNN + 10d → notify (within 14d window)" 0 ;;
	close\|*) print_result "t2711: origin:interactive + Ref #NNN + 10d → notify (within 14d window)" 1 "got: $decision (must NOT close within 14d window)" ;;
	*) print_result "t2711: origin:interactive + Ref #NNN + 10d → notify (within 14d window)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6d-pre: origin:interactive + reference + 8d old → notify (AC1 t2711 Q2)
#              8d is within the 14d extended window — must not close.
# =============================================================================

PR_INTERACTIVE_8D=$(mkpr 635 "DIRTY" \
	"$(iso_n_seconds_ago $((8 * 86400)))" \
	"$(iso_n_seconds_ago $((4 * 86400)))" \
	"marcusquinn" \
	"feature/baz-8d" \
	'["origin:interactive"]' \
	"Implementing the plan. For #99999.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_8D" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|origin-interactive-referenced-within-extended-window) print_result "t2711 AC1: origin:interactive + ref + 8d old → notify (within 14d window)" 0 ;;
	close\|*) print_result "t2711 AC1: origin:interactive + ref + 8d old → notify (within 14d window)" 1 "got: $decision (must NOT close within 14d window)" ;;
	*) print_result "t2711 AC1: origin:interactive + ref + 8d old → notify (within 14d window)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6d-post: origin:interactive + reference + 15d old → close (AC2 t2711 Q2)
#               15d exceeds the 14d extended window — should fall through to
#               the normal age/idle close heuristic.
#               Use DIRTY_PR_CLOSE_MIN_AGE_INTERACTIVE override to 1d so the
#               test is deterministic regardless of real wall-clock time.
# =============================================================================

DIRTY_PR_CLOSE_MIN_AGE_INTERACTIVE=86400  # override to 1d for this test
PR_INTERACTIVE_15D=$(mkpr 636 "DIRTY" \
	"$(iso_n_seconds_ago $((15 * 86400)))" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"marcusquinn" \
	"feature/baz-15d" \
	'["origin:interactive"]' \
	"Implementing the plan. For #99999.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_15D" "test/repo" "" "marcusquinn")
DIRTY_PR_CLOSE_MIN_AGE_INTERACTIVE=1209600  # restore default
case "$decision" in
	close\|stale-and-idle) print_result "t2711 AC2: origin:interactive + ref + beyond extended window → close" 0 ;;
	notify\|*) print_result "t2711 AC2: origin:interactive + ref + beyond extended window → close" 1 "got: $decision (must close beyond 14d window when stale+idle)" ;;
	*) print_result "t2711 AC2: origin:interactive + ref + beyond extended window → close" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6d-noninteractive: non-interactive PR still uses 7d threshold (AC3 t2711)
#                         An origin:worker PR at 10d old should still close —
#                         it does not get the extended 14d window.
# =============================================================================

PR_WORKER_10D=$(mkpr 637 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"some-external-user" \
	"feature/worker-10d" \
	'["origin:worker"]' \
	"Some worker PR. Resolves #88888.")

decision=$(_dirty_pr_classify "$PR_WORKER_10D" "test/repo" "" "marcusquinn")
case "$decision" in
	close\|stale-and-idle) print_result "t2711 AC3: non-interactive PR at 10d → close (7d threshold unaffected)" 0 ;;
	notify\|*) print_result "t2711 AC3: non-interactive PR at 10d → close (7d threshold unaffected)" 1 "got: $decision (non-interactive must still close at 7d+)" ;;
	*) print_result "t2711 AC3: non-interactive PR at 10d → close (7d threshold unaffected)" 1 "got: $decision" ;;
esac

# =============================================================================
# Test 6d: parent-task label still takes precedence over the narrowed rule.
#          Even if an interactive PR has a valid reference, the parent-task
#          label must still force notify (line 423-425 precedence, t1986).
# =============================================================================

PR_INTERACTIVE_PARENT=$(mkpr 640 "DIRTY" \
	"$(iso_n_seconds_ago $((10 * 86400)))" \
	"$(iso_n_seconds_ago $((5 * 86400)))" \
	"marcusquinn" \
	"feature/baz-parent" \
	'["origin:interactive", "parent-task"]' \
	"Parent planning PR. Resolves #12345.")

decision=$(_dirty_pr_classify "$PR_INTERACTIVE_PARENT" "test/repo" "" "marcusquinn")
case "$decision" in
	notify\|parent-task-label) print_result "t2708: parent-task precedence preserved over narrowed rule" 0 ;;
	*) print_result "t2708: parent-task precedence preserved over narrowed rule" 1 "got: $decision (must still notify with parent-task-label reason)" ;;
esac

# =============================================================================
# Test 7: idempotency — cooldown is honoured
# =============================================================================

# Record a fake action for PR #100 in test/repo and verify _dps_recently_actioned returns true.
_dps_state_record_action "test/repo#100" "rebase"
if _dps_recently_actioned "test/repo#100"; then
	print_result "idempotency: cooldown blocks re-action" 0
else
	print_result "idempotency: cooldown blocks re-action" 1 "_dps_recently_actioned returned false"
fi
if _dps_recently_actioned "test/repo#9999-unknown"; then
	print_result "idempotency: unknown key is not blocked" 1 "_dps_recently_actioned returned true for unknown key"
else
	print_result "idempotency: unknown key is not blocked" 0
fi

# Force cooldown expiry by rewriting last_action_epoch to a distant past.
ancient_state=$(jq --arg k "test/repo#100" \
	'.[$k].last_action_epoch = 1' \
	"$DIRTY_PR_SWEEP_STATE_FILE")
printf '%s' "$ancient_state" >"$DIRTY_PR_SWEEP_STATE_FILE"
if _dps_recently_actioned "test/repo#100"; then
	print_result "idempotency: stale cooldown expires" 1 "_dps_recently_actioned returned true on ancient timestamp"
else
	print_result "idempotency: stale cooldown expires" 0
fi

# =============================================================================
# Test 8: dry-run — close action never calls gh pr close
# =============================================================================

# Stub gh to record calls.
STUB_DIR="${TEST_ROOT}/stubs"
mkdir -p "$STUB_DIR"
GH_CALLS_LOG="${TEST_ROOT}/gh-calls.log"
: >"$GH_CALLS_LOG"
cat >"${STUB_DIR}/gh" <<STUB
#!/usr/bin/env bash
printf 'gh %s\n' "\$*" >> "$GH_CALLS_LOG"
# Handle common read-only reads with empty defaults
case "\$1" in
	pr)
		case "\$2" in
			view) printf '{"comments":[]}' ;;
			close) : ;;  # noop in stub
			comment) : ;;
		esac
		;;
	issue)
		case "\$2" in
			view) printf '{"state":"OPEN","labels":[]}' ;;
		esac
		;;
	api)
		case "\$2" in
			user) printf '{"login":"marcusquinn"}' ;;
		esac
		;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/gh"

# Prepend stub to PATH
PATH_ORIG="$PATH"
export PATH="${STUB_DIR}:${PATH}"

# Clear action state so the stub call isn't cooldown-skipped.
printf '%s' '{}' >"$DIRTY_PR_SWEEP_STATE_FILE"

# Dry-run close on PR #200 (stale) — should NOT call `gh pr close`.
_DIRTY_PR_SWEEP_DRY_RUN=1
_dirty_pr_action_close 200 "test/repo" >/dev/null 2>&1
if grep -q 'gh pr close 200' "$GH_CALLS_LOG"; then
	print_result "dry-run: close does NOT execute gh pr close" 1 "gh pr close was called"
else
	print_result "dry-run: close does NOT execute gh pr close" 0
fi
_DIRTY_PR_SWEEP_DRY_RUN=0

# Restore PATH.
export PATH="$PATH_ORIG"

# =============================================================================
# Test 9: interval gate — sweep early-returns when interval not elapsed
# =============================================================================

# Reset the state file so no repos are iterated (empty repos.json).
printf '%s' '{}' >"$DIRTY_PR_SWEEP_STATE_FILE"
# Write a "recent" timestamp to the last-run file.
date +%s >"$DIRTY_PR_SWEEP_LAST_RUN"
export DIRTY_PR_SWEEP_INTERVAL=3600  # 1h — now not elapsed
# Capture interval-gate log line to confirm the gate fired.
INTERVAL_LOG="${TEST_ROOT}/interval.log"
: >"$INTERVAL_LOG"
LOGFILE="$INTERVAL_LOG" dirty_pr_sweep_all_repos
if grep -q 'interval-gate' "$INTERVAL_LOG"; then
	print_result "interval gate: early-return when not due" 0
else
	print_result "interval gate: early-return when not due" 1 "log did not show 'interval-gate'"
fi

# =============================================================================
# Test 10: response-metered GraphQL population read is exact and fail-closed
# =============================================================================

cat >"${STUB_DIR}/gh" <<'STUB'
#!/usr/bin/env bash
printf 'response=%s route=%s gh %s\n' \
	"${AIDEVOPS_GH_GRAPHQL_COST_FROM_RESPONSE:-}" \
	"${AIDEVOPS_GH_ROUTE_DECISION:-}" "$*" >>"$GH_CALLS_LOG"
[[ "${1:-}" == "api" && "${2:-}" == "graphql" ]] || exit 1
case "${DIRTY_GRAPHQL_MODE:-valid}" in
	missing-cost)
		printf '%s\n' '{"data":{"repository":{"pullRequests":{"nodes":[]}}}}'
		;;
	partial-labels)
		printf '%s\n' '{"data":{"repository":{"pullRequests":{"nodes":[{"number":77,"title":"dirty","mergeStateStatus":"DIRTY","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-02T00:00:00Z","author":{"login":"worker"},"labels":{"nodes":[{"name":"origin:worker"}],"pageInfo":{"hasNextPage":true}},"headRefName":"fix/dirty","baseRefName":"main","body":"For #77"}]}},"rateLimit":{"cost":1}}}'
		;;
	*)
		printf '%s\n' '{"data":{"repository":{"pullRequests":{"nodes":[{"number":77,"title":"dirty","mergeStateStatus":"DIRTY","createdAt":"2026-08-01T00:00:00Z","updatedAt":"2026-08-02T00:00:00Z","author":{"login":"worker"},"labels":{"nodes":[{"name":"origin:worker"}],"pageInfo":{"hasNextPage":false}},"headRefName":"fix/dirty","baseRefName":"main","body":"For #77"}]}},"rateLimit":{"cost":1}}}'
		;;
esac
exit 0
STUB
chmod +x "${STUB_DIR}/gh"
: >"$GH_CALLS_LOG"
export PATH="${STUB_DIR}:${PATH_ORIG}"
export GH_CALLS_LOG

DIRTY_GRAPHQL_MODE=valid
export DIRTY_GRAPHQL_MODE
graphql_out=""
graphql_rc=0
graphql_out=$(_dirty_pr_sweep_open_prs_graphql "test/repo" 100) || graphql_rc=$?
if [[ "$graphql_rc" -eq 0 ]] \
	&& printf '%s' "$graphql_out" | jq -e 'length == 1 and .[0].number == 77 and .[0].labels[0].name == "origin:worker"' >/dev/null \
	&& grep -q 'response=1 route=dirty-pr-sweep-exact-cost gh api graphql' "$GH_CALLS_LOG"; then
	print_result "exact GraphQL population read returns compatible JSON and response-owned cost" 0
else
	print_result "exact GraphQL population read returns compatible JSON and response-owned cost" 1 "rc=${graphql_rc}; output=${graphql_out}"
fi

DIRTY_GRAPHQL_MODE=missing-cost
graphql_rc=0
_dirty_pr_sweep_open_prs_graphql "test/repo" 100 >/dev/null 2>&1 || graphql_rc=$?
if [[ "$graphql_rc" -ne 0 ]]; then
	print_result "exact GraphQL population read rejects missing response cost" 0
else
	print_result "exact GraphQL population read rejects missing response cost" 1
fi

DIRTY_GRAPHQL_MODE=partial-labels
graphql_rc=0
_dirty_pr_sweep_open_prs_graphql "test/repo" 100 >/dev/null 2>&1 || graphql_rc=$?
if [[ "$graphql_rc" -ne 0 ]]; then
	print_result "exact GraphQL population read rejects partial label metadata" 0
else
	print_result "exact GraphQL population read rejects partial label metadata" 1
fi
export PATH="$PATH_ORIG"

# =============================================================================
# Summary
# =============================================================================

printf '\n---\nTotal: %d run, %d failed\n' "$TESTS_RUN" "$TESTS_FAILED"
[[ "$TESTS_FAILED" -eq 0 ]]
