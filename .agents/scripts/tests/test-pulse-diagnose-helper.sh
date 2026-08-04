#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression tests for pulse-diagnose-helper.sh (t2714)
#
# Uses a fixture pulse.log with 3+ distinct rule outcomes and stubs gh.
# Does NOT require live network or real pulse.log.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../pulse-diagnose-helper.sh"
PASS=0
FAIL=0
TOTAL=0

# =============================================================================
# Test framework
# =============================================================================

assert_eq() {
	local desc="$1" expected="$2" actual="$3"
	TOTAL=$((TOTAL + 1))
	if [[ "$expected" == "$actual" ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected: %s\n    actual:   %s\n' "$desc" "$expected" "$actual"
	fi
	return 0
}

assert_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TOTAL=$((TOTAL + 1))
	if printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected to contain: %s\n    actual: %s\n' "$desc" "$needle" "$haystack"
	fi
	return 0
}

assert_not_contains() {
	local desc="$1" needle="$2" haystack="$3"
	TOTAL=$((TOTAL + 1))
	if ! printf '%s' "$haystack" | grep -qF "$needle" 2>/dev/null; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s\n    expected NOT to contain: %s\n' "$desc" "$needle"
	fi
	return 0
}

assert_exit_code() {
	local desc="$1" expected="$2" actual="$3"
	TOTAL=$((TOTAL + 1))
	if [[ "$expected" -eq "$actual" ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ %s\n' "$desc"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ %s (expected exit %d, got %d)\n' "$desc" "$expected" "$actual"
	fi
	return 0
}

# =============================================================================
# Fixture setup
# =============================================================================

TMPDIR_TEST=$(mktemp -d)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

FIXTURE_LOGFILE="${TMPDIR_TEST}/pulse.log"
FIXTURE_LOGDIR="${TMPDIR_TEST}"
FIXTURE_METRICS="${TMPDIR_TEST}/headless-runtime-metrics.jsonl"
FIXTURE_STATS="${TMPDIR_TEST}/pulse-stats.json"
FIXTURE_GH_API_LOG="${TMPDIR_TEST}/gh-api-calls.log"
FIXTURE_TIMER="${TMPDIR_TEST}/aidevops-supervisor-pulse.timer"
FIXTURE_GH_COOLDOWN="${TMPDIR_TEST}/gh-secondary-cooldown.json"
FIXTURE_GH_COOLDOWN_EVENTS="${TMPDIR_TEST}/gh-cooldown-events.jsonl"
WRAPPER_GH_COOLDOWN="${TMPDIR_TEST}/wrapper-gh-secondary-cooldown.json"
WRAPPER_GH_COOLDOWN_EVENTS="${TMPDIR_TEST}/wrapper-gh-cooldown-events.jsonl"
FIXTURE_BLOCKERS="${TMPDIR_TEST}/worker-progress-blockers.jsonl"
FIXTURE_THREAD_STATE_DIR="${TMPDIR_TEST}/pr-review-thread-response"
FIXTURE_DISPATCH_LEDGER="${TMPDIR_TEST}/dispatch-ledger.jsonl"
FIXTURE_WORKTREE_REGISTRY="${TMPDIR_TEST}/worktree-registry.db"
FIXTURE_ANCILLARY_REMOTE="${TMPDIR_TEST}/ancillary-remote.git"
FIXTURE_ANCILLARY_WORKTREE="${TMPDIR_TEST}/ancillary-worktree"
export PULSE_DIAGNOSE_BLOCKER_LOG="$FIXTURE_BLOCKERS"
export PULSE_DIAGNOSE_THREAD_RESPONSE_STATE_DIR="$FIXTURE_THREAD_STATE_DIR"
export PULSE_DIAGNOSE_DISPATCH_LEDGER_FILE="$FIXTURE_DISPATCH_LEDGER"
export PULSE_DIAGNOSE_WORKTREE_REGISTRY_DB="$FIXTURE_WORKTREE_REGISTRY"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_FILE="$WRAPPER_GH_COOLDOWN"
export AIDEVOPS_GH_SECONDARY_COOLDOWN_EVENTS_FILE="$WRAPPER_GH_COOLDOWN_EVENTS"
unset AIDEVOPS_GH_PR_VIEW_CACHE_DIR

mkdir -p "$FIXTURE_THREAD_STATE_DIR"
git init --bare -q "$FIXTURE_ANCILLARY_REMOTE"
git clone -q "$FIXTURE_ANCILLARY_REMOTE" "$FIXTURE_ANCILLARY_WORKTREE" 2>/dev/null
git -C "$FIXTURE_ANCILLARY_WORKTREE" config user.name "aidevops-test"
git -C "$FIXTURE_ANCILLARY_WORKTREE" config user.email "aidevops-test@example.invalid"
printf 'tracked\n' >"${FIXTURE_ANCILLARY_WORKTREE}/diagnostic.txt"
git -C "$FIXTURE_ANCILLARY_WORKTREE" add diagnostic.txt
git -C "$FIXTURE_ANCILLARY_WORKTREE" commit -q -m "fixture"
git -C "$FIXTURE_ANCILLARY_WORKTREE" branch -M feature/t2711
git -C "$FIXTURE_ANCILLARY_WORKTREE" push -q -u origin feature/t2711
printf 'dirty\n' >>"${FIXTURE_ANCILLARY_WORKTREE}/diagnostic.txt"

cat >"${FIXTURE_THREAD_STATE_DIR}/marcusquinn-aidevops-20340.state" <<'ANCILLARY_STATE'
attempt_count=2
dispatched_at=1785834000
blocked_by=worker
ANCILLARY_STATE
cat >"${FIXTURE_THREAD_STATE_DIR}/marcusquinn-aidevops-20340.outcome" <<'ANCILLARY_OUTCOME'
reason=process_exit
session_count=2
finished_at=1785834121
ANCILLARY_OUTCOME
jq -cn --arg path "$FIXTURE_ANCILLARY_WORKTREE" \
	'{session_key:"pr-review-thread-response-marcusquinn-aidevops-20340",status:"failed",lease_phase:"prelaunch",pid:99999999,worktree_path:$path,updated_at:"2026-08-04T09:02:01Z"}' \
	>"$FIXTURE_DISPATCH_LEDGER"
sqlite3 "$FIXTURE_WORKTREE_REGISTRY" \
	"CREATE TABLE worktree_owners (worktree_path TEXT PRIMARY KEY, owner_pid INTEGER, owner_session TEXT, owner_batch TEXT, task_id TEXT, created_at TEXT); INSERT INTO worktree_owners VALUES ('${FIXTURE_ANCILLARY_WORKTREE}',99999999,'pr-review-thread-response-marcusquinn-aidevops-20340','batch-1','20300','2026-08-04T09:01:00Z');"

# Create fixture pulse.log with 3+ distinct rule outcomes:
# 1. PR #20329: escalated by dirty-pr-sweep (notify), then admin-bypass merge
# 2. PR #20336: auto-merged (origin:interactive lifecycle)
# 3. PR #20340: skipped due to failing checks
cat > "$FIXTURE_LOGFILE" <<'FIXTURE'
2026-04-21T17:45:03Z [pulse-dirty-pr-sweep] PR #20329 (marcusquinn/aidevops): decision=notify reason=origin-interactive-orphan
2026-04-21T17:45:04Z [pulse-dirty-pr-sweep] PR #20329 (marcusquinn/aidevops): notified (origin-interactive-orphan)
2026-04-21T18:30:00Z [pulse-wrapper] Review bot gate: PASS for PR #20336 in marcusquinn/aidevops
2026-04-21T18:30:01Z [pulse-wrapper] approve_collaborator_pr: PR #20336 is self-authored (marcusquinn) — skipping approval (--admin handles it)
2026-04-21T18:30:02Z [pulse-wrapper] Deterministic merge: merged PR #20336 in marcusquinn/aidevops
2026-04-21T18:30:03Z [pulse-merge] auto-merged origin:interactive PR #20336 (author=marcusquinn, role=admin)
2026-04-21T19:00:00Z [pulse-wrapper] Merge pass: skipping PR #20340 in marcusquinn/aidevops — 2 required status check(s) failing (t2104)
2026-04-21T19:00:01Z [pulse-wrapper] _dispatch_ci_fix_worker: routed CI failure feedback from PR #20340 to issue #20300 in marcusquinn/aidevops
2026-04-21T19:10:00Z [shared-gh-wrappers] gh_pr_view cache hit for PR #20340
2026-04-21T19:10:01Z [shared-gh-wrappers] gh_pr_view cache miss for PR #20340
2026-04-21T19:10:02Z [shared-gh-wrappers] FORCE_REST reads enabled for low GraphQL budget
2026-04-21T19:10:03Z [pulse-wrapper] Merge pass: PR #20340 in marcusquinn/aidevops — mergeable resolved to MERGEABLE after retry
2026-04-21T19:10:04Z [pulse-wrapper] REST-first read routing enabled for REST-equivalent gh issue/pr list/view calls (GH#22525)
2026-04-21T19:10:05Z [pulse-wrapper] Per-cycle PR view cache enabled for duplicate repo#PR reads ttl=3600s (GH#23433/GH#23604)
2026-04-21T19:30:00Z [pulse-dirty-pr-sweep] sweep complete: rebased=1 closed=0 notified=2
2026-04-21T20:00:00Z [pulse-wrapper] Deterministic merge pass complete: merged=3, closed_conflicting=0, failed=0
2026-04-21T20:01:00Z [pulse-wrapper] Review bot gate: PASS for PR #28869 in marcusquinn/aidevops
2026-04-21T20:01:01Z [pulse-mystery] first unknown observation for PR #28869
2026-04-21T20:01:02Z [pulse-mystery] second unknown observation for PR #28869
2026-04-21T20:02:00Z [pulse-wrapper] Merge pass: skipping PR #29285 in marcusquinn/aidevops — 1 required status check(s) failing (t2104)
FIXTURE

cat >"$FIXTURE_BLOCKERS" <<'BLOCKERS'
{"schema":"aidevops-worker-blocker/v1","ts":100,"timestamp":"2026-04-27T09:00:00Z","event":"permission_request_captured","status":"blocked","reason":"permission_required","blocking":true,"source":"opencode-permission-broker","issue_number":21860,"repo_slug":"marcusquinn/aidevops","session_key":"issue-21860","request_id":"perm-source"}
{"schema":"aidevops-worker-blocker/v1","ts":110,"timestamp":"2026-04-27T09:01:00Z","event":"permission_grant_applied","status":"resuming","reason":"scoped_permission_granted","blocking":false,"source":"opencode-config-hook","issue_number":21860,"repo_slug":"marcusquinn/aidevops","session_key":"issue-21860","request_id":"perm-envelope"}
{"schema":"aidevops-worker-blocker/v1","ts":120,"timestamp":"2026-04-27T09:02:00Z","event":"permission_request_non_grantable","status":"blocked","reason":"permission_non_grantable","blocking":true,"source":"opencode-permission-broker","issue_number":21860,"repo_slug":"marcusquinn/aidevops","session_key":"issue-21860-retry","request_id":"perm-sensitive"}
{"schema":"aidevops-worker-blocker/v1","ts":130,"timestamp":"2026-04-27T09:03:00Z","event":"issue_terminal_reconciled","status":"resolved","reason":"issue_closed_completed","blocking":false,"source":"dependency-event-reconciler","issue_number":21860,"repo_slug":"marcusquinn/aidevops","session_key":"issue-21860-retry","request_id":"perm-sensitive"}
malformed-row
BLOCKERS

cat > "$FIXTURE_TIMER" <<'TIMER'
[Unit]
Description=aidevops supervisor pulse Timer

[Timer]
 ; Leading comment with an equals sign should be ignored: ignored=yes
OnActiveSec = 10s
OnBootSec=180s
OnUnitActiveSec = 180s
Persistent=true
TIMER

cat > "$FIXTURE_STATS" <<'STATS'
{
  "pulse_dispatch_circuit_broken": 2,
  "pulse_graphql_budget_reserve_mode": 3,
  "pulse_graphql_budget_stage_deferred": 4,
  "pulse_graphql_budget_force_rest_reads": 5,
  "pulse_cache_prime_runs": 6,
  "pulse_cache_prime_failures": 1
}
STATS

cat > "$FIXTURE_GH_API_LOG" <<'GHAPILOG'
1700000000	gh_pr_view_cache	rest	gh-pat	rest-core	hit	4999
1700000001	gh_pr_view_cache	rest	gh-pat	rest-core	miss	4998
1700000002	gh_pr_view_cache	rest	gh-pat	rest-core	stale	4997
1700000003	gh_pr_view_cache	rest	gh-pat	rest-core	bypass	4996
1700000004	gh_pr_view_cache	rest	gh-pat	rest-core	store	4995
1700000005	gh_pr_view_cache	rest	gh-pat	rest-core	invalid-json	4994
1700000006	gh_pr_view_cache	rest	gh-pat	rest-core	bypass-disabled	4993
1700000007	rest_pr_view_cache	rest	gh-pat	rest-core	hit	4992
1700000008	rest_pr_view_cache	rest	gh-pat	rest-core	miss	4991
1700000009	rest_pr_view_cache	rest	gh-pat	rest-core	store	4990
1700000010	rest_pr_view_cache	rest	gh-pat	rest-core	invalid-json	4989
1700000011	rest_pr_view_cache	rest	gh-pat	rest-core	bypass-disabled	4988
1700000012	pulse-wrapper.sh	graphql	gh-pat	graphql	graphql-selected	1200
1700000013	_rest_pr_view	rest	gh-pat	rest-core	rest-core-selected	4987
GHAPILOG

cat > "$FIXTURE_GH_COOLDOWN" <<'COOLDOWN'
{"reason":"github-secondary-rate-limit","expires_at":9999999999,"diagnostic":{"endpoint_family":"rest-search","body_message_class":"secondary-rate-limit","recent_secondary_count_5m":2}}
COOLDOWN

cat > "$FIXTURE_GH_COOLDOWN_EVENTS" <<'COOLDOWNEVENTS'
{"timestamp":1700000014,"body_message_class":"secondary-rate-limit"}
{"timestamp":1700000015,"body_message_class":"abuse-detection"}
COOLDOWNEVENTS

# Also create a rotated log with older PR #20329 entries
cat > "${TMPDIR_TEST}/pulse.log.1" <<'ROTATED'
2026-04-20T10:00:00Z [pulse-wrapper] Merge pass: skipping PR #20329 in marcusquinn/aidevops — reviewDecision=CHANGES_REQUESTED
ROTATED

# Create a gh stub that returns canned data
GH_STUB="${TMPDIR_TEST}/gh"
cat > "$GH_STUB" <<'GHSTUB'
#!/usr/bin/env bash
# gh stub for testing pulse-diagnose-helper.sh
if [[ "$*" == *"pr view"*"20329"* ]]; then
  cat <<'JSON'
{"number":20329,"title":"t2710: fix dirty-pr-sweep","state":"CLOSED","author":{"login":"marcusquinn"},"mergedAt":null,"closedAt":"2026-04-21T18:01:09Z","createdAt":"2026-04-20T09:00:00Z","labels":[{"name":"origin:interactive"}],"reviewDecision":"CHANGES_REQUESTED","mergeStateStatus":"DIRTY","headRefName":"feature/t2710","baseRefName":"main","isDraft":false}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"20336"* ]]; then
  cat <<'JSON'
{"number":20336,"title":"t2708: fix interactive sweep","state":"MERGED","author":{"login":"marcusquinn"},"mergedAt":"2026-04-21T18:30:02Z","closedAt":"2026-04-21T18:30:02Z","createdAt":"2026-04-21T17:00:00Z","labels":[{"name":"origin:interactive"}],"reviewDecision":"APPROVED","mergeStateStatus":"CLEAN","headRefName":"feature/t2708","baseRefName":"main","isDraft":false}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"20340"* ]]; then
  cat <<'JSON'
{"number":20340,"title":"t2711: add rate limit guard","state":"OPEN","author":{"login":"marcusquinn"},"mergedAt":null,"closedAt":null,"createdAt":"2026-04-21T18:50:00Z","labels":[{"name":"origin:worker"}],"reviewDecision":"","mergeStateStatus":"BLOCKED","headRefName":"feature/t2711","baseRefName":"main","isDraft":false}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"99999"* ]]; then
  echo '{"number":99999,"title":"ghost PR","state":"MERGED","author":{"login":"someone"},"mergedAt":"2026-04-21T12:00:00Z","closedAt":"2026-04-21T12:00:00Z","createdAt":"2026-04-21T11:00:00Z","labels":[],"reviewDecision":"","mergeStateStatus":"","headRefName":"feature/ghost","baseRefName":"main","isDraft":false}'
  exit 0
fi
if [[ "$*" == *"pr view"*"21876"* ]]; then
  cat <<'JSON'
{"number":21876,"title":"t3210: fix re-dispatch on existing branch","state":"CLOSED","author":{"login":"alex-solovyev"},"mergedAt":null,"closedAt":"2026-04-28T10:00:00Z","createdAt":"2026-04-27T09:00:00Z","labels":[{"name":"origin:worker"}],"reviewDecision":"","mergeStateStatus":"CONFLICTING","headRefName":"feature/auto-20260427-gh21860","baseRefName":"main","isDraft":false}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"28869"* ]]; then
  cat <<'JSON'
{"number":28869,"title":"fix pulse diagnostics","state":"OPEN","author":{"login":"worker"},"mergedAt":null,"closedAt":null,"createdAt":"2026-07-29T19:21:19Z","labels":[{"name":"origin:worker"}],"reviewDecision":"","mergeStateStatus":"BLOCKED","headRefName":"feature/auto-20260729-192119-gh28780","baseRefName":"main","isDraft":true}
JSON
  exit 0
fi
if [[ "$*" == *"pr view"*"29285"* ]]; then
  sleep 4
  if [[ -n "${PULSE_DIAGNOSE_TEST_TIMEOUT_SENTINEL:-}" ]]; then
    printf 'unbounded\n' >"$PULSE_DIAGNOSE_TEST_TIMEOUT_SENTINEL"
  fi
  exit 0
fi
if [[ "$*" == *"issue view"*"21860"* ]]; then
  cat <<'JSON'
{"number":21860,"title":"t3206: worker re-dispatch loops on same branch","state":"OPEN","author":{"login":"marcusquinn"},"createdAt":"2026-04-26T08:00:00Z","closedAt":null,"labels":[{"name":"auto-dispatch"},{"name":"status:queued"}],"assignees":[]}
JSON
  exit 0
fi
if [[ "$*" == *"issue view"*"99998"* ]]; then
  cat <<'JSON'
{"number":99998,"title":"ghost issue","state":"CLOSED","author":{"login":"marcusquinn"},"createdAt":"2026-04-01T00:00:00Z","closedAt":"2026-04-02T00:00:00Z","labels":[],"assignees":[]}
JSON
  exit 0
fi
if [[ "$*" == *"issue view"*"28780"* ]]; then
  echo '{"number":28780,"title":"draft discovery fixture","state":"OPEN","author":{"login":"marcusquinn"},"createdAt":"2026-07-29T00:00:00Z","closedAt":null,"labels":[],"assignees":[]}'
  exit 0
fi
if [[ "$*" == *"issue view"*"2878"* ]]; then
  echo '{"number":2878,"title":"near match fixture","state":"OPEN","author":{"login":"marcusquinn"},"createdAt":"2026-07-29T00:00:00Z","closedAt":null,"labels":[],"assignees":[]}'
  exit 0
fi
if [[ "$*" == *"api"*"issues/21860/timeline"* ]]; then
  cat <<'JSON'
[{"event":"cross-referenced","source":{"issue":{"number":21876,"pull_request":{"url":"https://api.github.com/repos/marcusquinn/aidevops/pulls/21876"}}}},{"event":"labeled","label":{"name":"auto-dispatch"}}]
JSON
  exit 0
fi
if [[ "$*" == *"api"*"issues/21860/comments"* ]]; then
  [[ "$*" == *"--paginate"*"--slurp"* ]] || exit 1
  cat <<'JSON'
[[{"created_at":"2026-04-27T10:00:00Z","user":{"login":"alex-solovyev"},"body":"WORKER_BRANCH_ORPHAN: existing PR #21876 for branch feature/auto-20260427-gh21860 already open\n<!-- ops:start -->\nworker-orphan comment\n<!-- ops:end -->"},{"created_at":"2026-04-27T10:05:00Z","user":{"login":"alex-solovyev"},"body":"WORKER_BRANCH_ORPHAN: second re-dispatch attempt detected on same branch"},{"created_at":"2026-04-27T10:06:00Z","user":{"login":"marcusquinn"},"body":"CLAIM_RELEASED reason=worker_worktree_continuation_state_rejected runner=runner-a exit=1 session_count=0"},{"created_at":"2026-04-27T10:07:00Z","user":{"login":"marcusquinn"},"body":"CLAIM_RELEASED reason=worker_worktree_owner_concurrent_mutation runner=runner-a exit=1 session_count=0"},{"created_at":"2026-04-27T10:10:00Z","user":{"login":"marcusquinn"},"body":"Looks like the pulse is looping on this one"}]]
JSON
  exit 0
fi
if [[ "$*" == *"api"*"issues/99998/timeline"* ]]; then
  echo '[]'
  exit 0
fi
if [[ "$*" == *"api"*"issues/99998/comments"* ]]; then
  [[ "$*" == *"--paginate"*"--slurp"* ]] || exit 1
  echo '[[]]'
  exit 0
fi
if [[ "$*" == *"api"*"timeline"* ]]; then
  echo '[]'
  exit 0
fi
if [[ "$*" == *"api"*"comments"* ]]; then
  echo '[]'
  exit 0
fi
if [[ "$*" == *"pr list"* ]]; then
  echo '[{"number":28869,"headRefName":"feature/auto-20260729-192119-gh28780"},{"number":28870,"headRefName":"feature/auto-20260729-192120-gh287800"}]'
  exit 0
fi
echo '{}' >&2
exit 1
GHSTUB
chmod +x "$GH_STUB"

# =============================================================================
# Tests
# =============================================================================

printf '\n=== pulse-diagnose-helper.sh regression tests ===\n\n'

# --- Test 1: help command ---
printf 'Test 1: help command\n'
output=$("$HELPER" help 2>&1) || true
assert_contains "help shows usage" "COMMANDS:" "$output"
assert_contains "help shows pr subcommand" "pr <N>" "$output"

# --- Test 2: rules command ---
printf '\nTest 2: rules command\n'
output=$("$HELPER" rules 2>&1) || true
assert_contains "rules lists inventory" "Rule Inventory" "$output"
assert_contains "rules shows pm-auto-merge-interactive" "pm-auto-merge-interactive" "$output"
assert_contains "rules shows dps-classify" "dps-classify" "$output"

# Count rules (≥30 required)
rule_count=$(echo "$output" | grep -c '^[a-z]' 2>/dev/null || true)
TOTAL=$((TOTAL + 1))
if [[ "$rule_count" -ge 30 ]]; then
	PASS=$((PASS + 1))
	printf '  ✓ rule count ≥30 (got %d)\n' "$rule_count"
else
	FAIL=$((FAIL + 1))
	printf '  ✗ rule count ≥30 (got %d)\n' "$rule_count"
fi

# --- Test 3: rules --json ---
printf '\nTest 3: rules --json\n'
output=$("$HELPER" rules --json 2>&1) || true
assert_contains "json output is array" "[" "$output"
# Validate it parses as JSON
if command -v jq >/dev/null 2>&1; then
	jq_count=$(echo "$output" | jq 'length' 2>/dev/null || echo 0)
	TOTAL=$((TOTAL + 1))
	if [[ "$jq_count" -ge 30 ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ JSON rules array has ≥30 entries (got %s)\n' "$jq_count"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ JSON rules array has ≥30 entries (got %s)\n' "$jq_count"
	fi
fi

# --- Test 4: PR #20329 — escalated dirty PR (notify + admin-bypass merge) ---
printf '\nTest 4: PR #20329 — escalated dirty PR\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20329 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows PR number" "PR #20329" "$output"
assert_contains "shows author" "marcusquinn" "$output"
assert_contains "classifies dirty-pr-sweep notify" "dps-classify" "$output"
assert_contains "shows CLOSED state" "CLOSED" "$output"
assert_contains "shows closed without merge" "closed without merge" "$output"
# Also picks up the rotated log entry
assert_contains "picks up rotated log (CHANGES_REQUESTED)" "pw-merge-skip-changes-requested" "$output"

# --- Test 5: PR #20336 — full auto-merge lifecycle ---
printf '\nTest 5: PR #20336 — auto-merge lifecycle\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows review bot gate PASS" "pw-review-bot-gate-pass" "$output"
assert_contains "shows approve skip (self-authored)" "pw-approve-self" "$output"
assert_contains "shows deterministic merge" "pw-merged" "$output"
assert_contains "shows auto-merge interactive" "pm-auto-merge-interactive" "$output"
assert_contains "outcome is pulse auto-merged" "pulse auto-merged" "$output"

# --- Test 6: PR #20340 — skipped due to failing checks ---
printf '\nTest 6: PR #20340 — failing checks skip\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20340 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows check failure skip" "pw-merge-skip-checks" "$output"
assert_contains "shows CI fix routing" "pw-route-ci-fix" "$output"
assert_contains "PR is still open" "still open" "$output"
assert_contains "shows integrated ancillary worker heading" "Ancillary workers:" "$output"
assert_contains "shows ancillary attempts and outcome" "thread-response  attempt=2  sessions=2  outcome=process_exit" "$output"
assert_contains "shows dead ancillary registry owner" "owner_status=dead" "$output"
assert_contains "shows dirty ancillary worktree without inventing a blocker" "dirty_files=1  blocked_reason=" "$output"
assert_contains "shows bounded dirty path evidence" "diagnostic.txt" "$output"

sqlite3 "$FIXTURE_WORKTREE_REGISTRY" \
	"UPDATE worktree_owners SET owner_session='unrelated-worker-session' WHERE worktree_path='${FIXTURE_ANCILLARY_WORKTREE}';"
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20340 --repo marcusquinn/aidevops --json 2>&1) || true
assert_eq "JSON rejects mismatched ancillary registry ownership" "mismatch" "$(printf '%s' "$output" | jq -r '.ancillary.registry.owner_status')"
assert_eq "JSON marks ancillary registry session mismatch" "false" "$(printf '%s' "$output" | jq -r '.ancillary.registry.matches_session')"
sqlite3 "$FIXTURE_WORKTREE_REGISTRY" \
	"UPDATE worktree_owners SET owner_session='pr-review-thread-response-marcusquinn-aidevops-20340' WHERE worktree_path='${FIXTURE_ANCILLARY_WORKTREE}';"

# --- Test 7: PR #99999 — zero pulse entries (admin-bypass) ---
printf '\nTest 7: PR #99999 — zero pulse entries (admin-bypass)\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 99999 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "notes no pulse entries" "no pulse log entries" "$output"
assert_contains "suggests admin bypass" "admin bypass" "$output"

# --- Test 8: --verbose flag ---
printf '\nTest 8: --verbose flag shows raw lines\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops --verbose 2>&1) || true

assert_contains "verbose shows RAW:" "RAW:" "$output"

# --- Test 8b: default PR output compacts unclassified events ---
printf '\nTest 8b: default PR output compacts unclassified events\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 28869 --repo marcusquinn/aidevops 2>&1) || true
assert_contains "default output summarizes unclassified events" "Unclassified pulse events: 2" "$output"
unclassified_rows=$(printf '%s' "$output" | grep -c 'Unclassified pulse log entry' 2>/dev/null || true)
assert_eq "default output omits repeated unclassified rows" "0" "$unclassified_rows"

output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 28869 --repo marcusquinn/aidevops --verbose 2>&1) || true
unclassified_rows=$(printf '%s' "$output" | grep -c 'Unclassified pulse log entry' 2>/dev/null || true)
assert_eq "verbose output retains every unclassified event" "2" "$unclassified_rows"
assert_contains "verbose output retains unknown raw evidence" "second unknown observation" "$output"

# --- Test 9: --json output ---
printf '\nTest 9: --json output for PR\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops --json 2>&1) || true

if command -v jq >/dev/null 2>&1; then
	json_event_count=$(echo "$output" | jq '.event_count' 2>/dev/null || echo 0)
	assert_eq "JSON event_count for PR #20336" "4" "$json_event_count"
	json_merged=$(echo "$output" | jq '.merged' 2>/dev/null || echo "false")
	assert_eq "JSON merged=true for PR #20336" "true" "$json_merged"
	output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
		PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
		PATH="${TMPDIR_TEST}:${PATH}" \
		"$HELPER" pr 28869 --repo marcusquinn/aidevops --json 2>&1) || true
	assert_eq "JSON preserves total event count" "3" "$(printf '%s' "$output" | jq '.event_count')"
	assert_eq "JSON preserves both unclassified events" "2" "$(printf '%s' "$output" | jq '[.events[] | select(.rule_id == "unclassified")] | length')"
	output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
		PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
		PATH="${TMPDIR_TEST}:${PATH}" \
		"$HELPER" pr 20340 --repo marcusquinn/aidevops --json 2>&1) || true
	assert_eq "JSON includes ancillary worker" "true" "$(printf '%s' "$output" | jq '.ancillary.present')"
	assert_eq "JSON includes ancillary dirty count" "1" "$(printf '%s' "$output" | jq '.ancillary.worktree.dirty_count')"
	assert_eq "JSON classifies ancillary owner dead" "dead" "$(printf '%s' "$output" | jq -r '.ancillary.registry.owner_status')"
fi

# --- Test 10: missing pulse.log ---
printf '\nTest 10: missing pulse.log handled gracefully\n'
output=$(PULSE_DIAGNOSE_LOGFILE="/nonexistent/pulse.log" \
	PULSE_DIAGNOSE_LOGDIR="/nonexistent" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "graceful with missing log" "no pulse log entries" "$output"

# --- Test 11: gh offline mode ---
printf '\nTest 11: gh offline mode\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_GH_OFFLINE=1 \
	"$HELPER" pr 20336 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "works with gh offline" "PR #20336" "$output"
assert_contains "author shows unknown when offline" "unknown" "$output"

# --- Test 11b: PR metadata timeout preserves log diagnostics ---
printf '\nTest 11b: PR metadata timeout preserves log diagnostics\n'
TIMEOUT_SENTINEL="${TMPDIR_TEST}/pr-metadata-unbounded"
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_TEST_TIMEOUT_SENTINEL="$TIMEOUT_SENTINEL" \
	AIDEVOPS_GH_READ_TIMEOUT=1 \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" pr 29285 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "timeout names the metadata deadline" "gh pr view timed out after 1s for PR #29285" "$output"
assert_contains "timeout still renders the PR heading" "PR #29285" "$output"
assert_contains "timeout reports unknown metadata" "Created: unknown" "$output"
assert_contains "timeout preserves collected pulse evidence" "pw-merge-skip-checks" "$output"
TOTAL=$((TOTAL + 1))
if [[ ! -e "$TIMEOUT_SENTINEL" ]]; then
	PASS=$((PASS + 1))
	printf '  ✓ metadata read was terminated before the slow command completed\n'
else
	FAIL=$((FAIL + 1))
	printf '  ✗ metadata read was not terminated before the slow command completed\n'
fi

# --- Test 12: no arguments ---
printf '\nTest 12: missing PR number shows error\n'
output=$(AIDEVOPS_BASH_REEXECED=1 "$HELPER" pr 2>&1) || true
rc=$?
assert_contains "shows usage on missing arg" "usage:" "$output"

# =============================================================================
# Tests — issue subcommand (t3258)
# =============================================================================

# Create a fixture pulse.log entry for PR #21876 (linked to issue #21860)
cat >> "$FIXTURE_LOGFILE" <<'ISSUE_FIXTURE'
2026-04-27T09:30:00Z [pulse-merge-conflict] Deterministic merge: closed conflicting PR #21876, linked issue left open for re-dispatch in marcusquinn/aidevops
2026-04-27T09:30:01Z [pulse-wrapper] Deterministic merge pass complete: merged=0, closed_conflicting=1, failed=0
2026-04-27T10:06:00Z [dispatch-backoff] BACKOFF_ACTIVE #21860 (marcusquinn/aidevops) count=2 cooldown=1800s wait=1500s next=2026-04-27T10:31:00
2026-04-27T10:07:00Z [pulse-wrapper] Launch validation failed for issue #21860 (marcusquinn/aidevops) — prelaunch failure reason=worker_worktree_continuation_state_rejected detected in worker.log
2026-04-27T10:08:00Z [pulse-wrapper] Launch validation failed for issue #21860 (marcusquinn/aidevops) — prelaunch failure reason=worker_worktree_owner_concurrent_mutation detected in worker.log
ISSUE_FIXTURE

now_epoch=$(date +%s)
recent_rate_limit_1=$(( now_epoch - 360 ))
recent_rate_limit_2=$(( now_epoch - 120 ))
recent_success=$(( now_epoch - 60 ))
cat > "$FIXTURE_METRICS" <<METRICS
{"ts":${recent_rate_limit_1},"role":"worker","session_key":"issue-21860","issue_number":21860,"repo_slug":"marcusquinn/aidevops","provider":"openai","model":"openai/gpt-5.5","result":"rate_limit","failure_reason":"rate_limit","exit_code":143}
{"ts":${recent_rate_limit_2},"role":"worker","session_key":"issue-21860","issue_number":21860,"repo_slug":"MarcusQuinn/aidevops","provider":"openai","model":"openai/gpt-5.5","result":"rate_limit_fast","failure_reason":"rate_limit_fast","provider_error_type":"rate_limit","provider_status":429,"exit_code":143}
{"ts":${recent_success},"role":"worker","session_key":"issue-21860","issue_number":21860,"repo_slug":"marcusquinn/aidevops","provider":"openai","model":"openai/gpt-5.5","result":"success","failure_reason":"","exit_code":0}
{"ts":${recent_success},"role":"worker","session_key":"issue-21860","issue_number":21860,"repo_slug":"example/other","provider":"openai","model":"openai/gpt-5.5","result":"rate_limit","failure_reason":"rate_limit","exit_code":143}
METRICS

# --- Test 13: issue subcommand — basic output ---
printf '\nTest 13: issue #21860 — WORKER_BRANCH_ORPHAN cascade\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_METRICS_FILE="$FIXTURE_METRICS" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 21860 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows issue number" "Issue #21860" "$output"
assert_contains "shows issue title" "worker re-dispatch" "$output"
assert_contains "shows issue labels" "auto-dispatch" "$output"
assert_contains "shows lifecycle comments section" "Lifecycle comments:" "$output"
assert_contains "shows worker progress blockers section" "Worker progress blockers:" "$output"
assert_contains "shows current blocker count" "Currently active: 0" "$output"
assert_contains "shows non-grantable blocker reason" "permission_non_grantable" "$output"
assert_contains "shows terminal blocker lifecycle event" "issue_closed_completed" "$output"
assert_contains "shows WORKER_BRANCH_ORPHAN comment" "WORKER_BRANCH_ORPHAN" "$output"
assert_contains "shows repeated attempts section" "Repeated attempts / dispatch backoff:" "$output"
assert_contains "shows metric attempt count" "Attempts in metrics: 3" "$output"
assert_contains "shows prelaunch failure count" "Prelaunch failures in pulse log: 2" "$output"
assert_contains "shows prelaunch continuation reason" "worker_worktree_continuation_state_rejected" "$output"
assert_contains "shows durable zero-attempt release count" "Zero-attempt releases in issue comments: 2" "$output"
assert_contains "shows durable zero-attempt release reason" "worker_worktree_owner_concurrent_mutation" "$output"
assert_contains "shows active backoff state" "Retry/backoff state: active=true" "$output"
assert_contains "shows dispatch backoff log event" "BACKOFF_ACTIVE #21860" "$output"
assert_contains "shows linked PRs section" "Linked/worker PRs:" "$output"
assert_contains "shows linked PR number" "PR #21876" "$output"
assert_contains "shows linked PR branch" "feature/auto-20260427-gh21860" "$output"

# --- Test 14: issue pulse log events for linked PR ---
printf '\nTest 14: issue #21860 — linked PR pulse events\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_METRICS_FILE="$FIXTURE_METRICS" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 21860 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows pulse events for linked PR" "pmc-close-conflicting" "$output"
assert_contains "shows pulse event count" "pulse events" "$output"

# --- Test 15: issue with no linked PRs or lifecycle comments ---
printf '\nTest 15: issue #99998 — no linked PRs or lifecycle comments\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 99998 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "shows issue number" "Issue #99998" "$output"
assert_contains "no comments found" "no comments found" "$output"
assert_contains "no linked PRs" "no linked or worker PRs found" "$output"

# --- Test 16: issue --json output ---
printf '\nTest 16: issue --json output\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_METRICS_FILE="$FIXTURE_METRICS" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 21860 --repo marcusquinn/aidevops --json 2>&1) || true

if command -v jq >/dev/null 2>&1; then
	json_issue_num=$(echo "$output" | jq '.issue_number' 2>/dev/null || echo 0)
	assert_eq "JSON issue_number for #21860" "21860" "$json_issue_num"
	json_state=$(echo "$output" | jq -r '.state' 2>/dev/null || echo "")
	assert_eq "JSON state is OPEN" "OPEN" "$json_state"
	json_lc_count=$(echo "$output" | jq '.lifecycle_comments | length' 2>/dev/null || echo 0)
	TOTAL=$((TOTAL + 1))
	if [[ "$json_lc_count" -ge 1 ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ JSON lifecycle_comments has ≥1 entry (got %s)\n' "$json_lc_count"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ JSON lifecycle_comments has ≥1 entry (got %s)\n' "$json_lc_count"
	fi
	json_pr_count=$(echo "$output" | jq '.linked_prs | length' 2>/dev/null || echo 0)
	TOTAL=$((TOTAL + 1))
	if [[ "$json_pr_count" -ge 1 ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ JSON linked_prs has ≥1 entry (got %s)\n' "$json_pr_count"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ JSON linked_prs has ≥1 entry (got %s)\n' "$json_pr_count"
	fi
	json_attempt_count=$(echo "$output" | jq '.repeated_attempts.attempt_count' 2>/dev/null || echo 0)
	assert_eq "JSON repeated_attempts attempt_count for #21860" "3" "$json_attempt_count"
	json_prelaunch_count=$(echo "$output" | jq '.repeated_attempts.prelaunch_failure_count' 2>/dev/null || echo 0)
	assert_eq "JSON repeated_attempts prelaunch_failure_count for #21860" "2" "$json_prelaunch_count"
	json_prelaunch_reason_count=$(echo "$output" | jq '.repeated_attempts.prelaunch_failure_reasons.worker_worktree_continuation_state_rejected' 2>/dev/null || echo 0)
	assert_eq "JSON repeated_attempts continuation reason count" "1" "$json_prelaunch_reason_count"
	json_zero_attempt_count=$(echo "$output" | jq '.repeated_attempts.zero_attempt_release_count' 2>/dev/null || echo 0)
	assert_eq "JSON repeated_attempts zero_attempt_release_count for #21860" "2" "$json_zero_attempt_count"
	json_zero_attempt_reason_count=$(echo "$output" | jq '.repeated_attempts.zero_attempt_release_reasons.worker_worktree_owner_concurrent_mutation' 2>/dev/null || echo 0)
	assert_eq "JSON repeated_attempts zero-attempt reason count" "1" "$json_zero_attempt_reason_count"
	json_backoff_active=$(echo "$output" | jq '.repeated_attempts.backoff_active' 2>/dev/null || echo "false")
	assert_eq "JSON repeated_attempts backoff_active=true" "true" "$json_backoff_active"
	json_dispatch_events=$(echo "$output" | jq '.repeated_attempts.dispatch_log_events | length' 2>/dev/null || echo 0)
	TOTAL=$((TOTAL + 1))
	if [[ "$json_dispatch_events" -ge 1 ]]; then
		PASS=$((PASS + 1))
		printf '  ✓ JSON repeated_attempts dispatch_log_events has ≥1 entry (got %s)\n' "$json_dispatch_events"
	else
		FAIL=$((FAIL + 1))
		printf '  ✗ JSON repeated_attempts dispatch_log_events has ≥1 entry (got %s)\n' "$json_dispatch_events"
	fi
	json_blocker_events=$(echo "$output" | jq '.progress_blockers.event_total' 2>/dev/null || echo 0)
	assert_eq "JSON progress_blockers event_total" "4" "$json_blocker_events"
	json_active_blockers=$(echo "$output" | jq '.progress_blockers.active_total' 2>/dev/null || echo 0)
	assert_eq "JSON progress_blockers active_total" "0" "$json_active_blockers"
fi

# --- Test 17: issue --verbose shows raw log lines ---
printf '\nTest 17: issue --verbose shows raw pulse log lines\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_METRICS_FILE="$FIXTURE_METRICS" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 21860 --repo marcusquinn/aidevops --verbose 2>&1) || true

assert_contains "verbose shows RAW: lines" "RAW:" "$output"

# --- Test 17b: empty timeline discovers exact draft branch and rejects near matches ---
printf '\nTest 17b: linked draft branch discovery and near-match rejection\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 28780 --repo marcusquinn/aidevops 2>&1) || true
assert_contains "matching draft branch is linked" "PR #28869" "$output"
assert_contains "issue output compacts unclassified events" "Unclassified pulse events: 2" "$output"

output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 2878 --repo marcusquinn/aidevops 2>&1) || true
assert_contains "near-match issue has no linked PR" "no linked or worker PRs found" "$output"

output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PATH="${TMPDIR_TEST}:${PATH}" \
	"$HELPER" issue 28780 --repo marcusquinn/aidevops --json 2>&1) || true
assert_eq "JSON includes branch-discovered draft PR" "28869" "$(printf '%s' "$output" | jq '.linked_prs[0].number')"
assert_eq "issue JSON preserves pulse event count" "3" "$(printf '%s' "$output" | jq '.linked_prs[0].pulse_event_count')"

# --- Test 18: issue gh offline mode ---
printf '\nTest 18: issue gh offline mode graceful degradation\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_LOGDIR="$TMPDIR_TEST" \
	PULSE_DIAGNOSE_GH_OFFLINE=1 \
	"$HELPER" issue 21860 --repo marcusquinn/aidevops 2>&1) || true

assert_contains "offline shows issue number" "Issue #21860" "$output"
assert_contains "offline shows state unknown" "unknown" "$output"
assert_contains "offline shows no comments" "no comments found" "$output"
assert_contains "offline shows no linked PRs" "no linked or worker PRs found" "$output"

# --- Test 19: issue missing number shows error ---
printf '\nTest 19: issue missing number shows error\n'
output=$(AIDEVOPS_BASH_REEXECED=1 "$HELPER" issue 2>&1) || true
assert_contains "issue shows usage on missing arg" "usage:" "$output"

# --- Test 20: help shows issue subcommand ---
printf '\nTest 20: help output includes issue subcommand\n'
output=$("$HELPER" help 2>&1) || true
assert_contains "help shows issue subcommand" "issue <N>" "$output"

# --- Test 21: api-budget compact sanitized summary ---
printf '\nTest 21: api-budget compact sanitized summary\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_STATS_FILE="$FIXTURE_STATS" \
	PULSE_DIAGNOSE_GH_API_LOG="$FIXTURE_GH_API_LOG" \
	PULSE_DIAGNOSE_GH_SECONDARY_COOLDOWN_FILE="$FIXTURE_GH_COOLDOWN" \
	PULSE_DIAGNOSE_GH_SECONDARY_COOLDOWN_EVENTS_FILE="$FIXTURE_GH_COOLDOWN_EVENTS" \
	PULSE_DIAGNOSE_SYSTEMD_TIMER_FILE="$FIXTURE_TIMER" \
	"$HELPER" api-budget 2>&1) || true

assert_contains "api-budget shows heading" "GitHub API Budget Compact Diagnostic" "$output"
assert_contains "api-budget shows circuit count" "GraphQL circuit-breaker trips: 2" "$output"
assert_contains "api-budget shows log hit miss" "gh_pr_view log hit/miss refs: 1/1" "$output"
assert_contains "api-budget shows exact cache decisions" "gh_pr_view exact cache:       hit=1 miss=1 stale=1 bypass=1 store=1 invalid_json=1 bypass_disabled=1" "$output"
assert_contains "api-budget shows REST cache decisions" "_rest_pr_view repo#PR cache:  hit=1 miss=1 stale=0 bypass=0 store=1 invalid_json=1 bypass_disabled=1" "$output"
assert_contains "api-budget shows cache key cardinality" "Cache key cardinality:" "$output"
assert_contains "api-budget shows mutation bypass attribution" "Mutation bypass attribution:  bypass_disabled_total=2 exact_output_disabled=1 rest_repo_pr_disabled=1 mutation_sensitive_confirmed_lower_bound=1 mutation_sensitive_inferred_from_disable=1 unattributed_lower_bound=0 attribution=cache_disable_env_records" "$output"
assert_contains "api-budget shows API calls by caller" "API calls by caller:" "$output"
assert_contains "api-budget explains shared cache dir state" "PR view shared cache dir:     shared=no present=unknown reason=diagnostic_env_unset" "$output"
assert_contains "api-budget shows secondary cooldown state" "Secondary cooldown state:     active=yes" "$output"
assert_contains "api-budget shows secondary cooldown class" "body=secondary-rate-limit" "$output"
assert_contains "api-budget shows systemd cadence" "Pulse systemd cadence:        source=systemd_user_timer present=yes configured_interval=180s on_active=10s" "$output"
assert_contains "api-budget shows log cadence" "Pulse log cadence:            cycles=4 lock_skips=0 cache_enabled_cycles=1" "$output"
assert_contains "api-budget shows cadence risk recommendation" "Cadence/API risk:             risk=watch reason=fast_timer_detected_without_lock_skip_evidence recommendation=verify_lock_skip_logs_and_shared_cache_then_raise_pulse_timer_to_180s_plus_if_absent" "$output"
assert_contains "api-budget warns before cache broadening" "Do not broaden gh_pr_view cache semantics" "$output"
assert_contains "api-budget documents unique PR limitation" "current gh-api rows do not carry repo#PR identifiers" "$output"
assert_contains "api-budget includes sanitized summary template" "Comment-ready summary template:" "$output"
assert_not_contains "api-budget omits repo slug" "marcusquinn/aidevops" "$output"

# --- Test 22: api-budget --json counters ---
printf '\nTest 22: api-budget --json counters\n'
output=$(PULSE_DIAGNOSE_LOGFILE="$FIXTURE_LOGFILE" \
	PULSE_DIAGNOSE_STATS_FILE="$FIXTURE_STATS" \
	PULSE_DIAGNOSE_GH_API_LOG="$FIXTURE_GH_API_LOG" \
	PULSE_DIAGNOSE_GH_SECONDARY_COOLDOWN_FILE="$FIXTURE_GH_COOLDOWN" \
	PULSE_DIAGNOSE_GH_SECONDARY_COOLDOWN_EVENTS_FILE="$FIXTURE_GH_COOLDOWN_EVENTS" \
	PULSE_DIAGNOSE_SYSTEMD_TIMER_FILE="$FIXTURE_TIMER" \
	"$HELPER" api-budget --json 2>&1) || true

if command -v jq >/dev/null 2>&1; then
	json_circuit=$(echo "$output" | jq '.graphql_circuit_breaker_trips' 2>/dev/null || echo 0)
	assert_eq "JSON api-budget circuit count" "2" "$json_circuit"
	json_cache_misses=$(echo "$output" | jq '.gh_pr_view_cache_misses' 2>/dev/null || echo 0)
	assert_eq "JSON api-budget cache misses" "1" "$json_cache_misses"
	json_callers_total=$(echo "$output" | jq '.api_calls_by_caller["pulse-wrapper.sh"].total' 2>/dev/null || echo 0)
	assert_eq "JSON api-budget caller totals" "1" "$json_callers_total"
	json_rest_cache=$(echo "$output" | jq -r '.rest_pr_view_repo_cache' 2>/dev/null || echo "")
	assert_contains "JSON api-budget REST cache counts" "miss=1" "$json_rest_cache"
	json_cache_dir=$(echo "$output" | jq -r '.pr_view_shared_cache_dir' 2>/dev/null || echo "")
	assert_contains "JSON api-budget shared cache dir explains state" "reason=diagnostic_env_unset" "$json_cache_dir"
	json_bypass=$(echo "$output" | jq -r '.mutation_bypass_attribution' 2>/dev/null || echo "")
	assert_contains "JSON api-budget bypass attribution has zero unattributed" "unattributed_lower_bound=0" "$json_bypass"
	json_cadence=$(echo "$output" | jq -r '.pulse_systemd_cadence' 2>/dev/null || echo "")
	assert_contains "JSON api-budget cadence" "on_active=10s" "$json_cadence"
	json_risk=$(echo "$output" | jq -r '.cadence_api_risk' 2>/dev/null || echo "")
	assert_contains "JSON api-budget cadence risk recommendation" "recommendation=verify_lock_skip_logs_and_shared_cache_then_raise_pulse_timer_to_180s_plus_if_absent" "$json_risk"
	json_cooldown=$(echo "$output" | jq -r '.secondary_cooldown_state' 2>/dev/null || echo "")
	assert_contains "JSON api-budget secondary cooldown" "active=yes" "$json_cooldown"
fi

# =============================================================================
# Summary
# =============================================================================

printf '\n=== Results: %d passed, %d failed, %d total ===\n\n' "$PASS" "$FAIL" "$TOTAL"

if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
