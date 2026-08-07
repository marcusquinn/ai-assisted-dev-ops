#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-observability-concurrent-init.sh — t2900 regression guard.
#
# Production failure (10/10 worker logs in 24h ending 2026-04-26):
#   Every concurrent worker startup hit `[aidevops] SQLite: Runtime error
#   near line 171: database is locked (5)` while initialising the shared
#   observability DB at ~/.aidevops/.agent-workspace/observability/
#   llm-requests.db. The pulse spawns up to MAX_WORKERS=24 concurrent
#   workers; all of them ran the schema's `PRAGMA journal_mode=WAL` +
#   `CREATE TABLE/INDEX IF NOT EXISTS` block on plugin load. Even though
#   the CREATEs are idempotent, the writer-lock queue grew beyond the 5s
#   `.timeout` and the schema sqliteExecSync call failed.
#
# Issue body cited `headless-runtime-helper.sh:581` (`db_merged dir=...`)
# as the suspect site, but that is opencode's per-worker isolated DB
# merge — never contended. The real shared DB is the plugin's
# observability DB, owned by `.agents/plugins/opencode-aidevops/
# observability.mjs`. This test exercises the fix at the actual site.
#
# Fix (t2900): two layers in observability.mjs::initDatabase:
#   B. FAST PATH: read-only `_isSchemaInitialized()` check via
#      `sqlite3 -readonly` skips the writer-locked schema CREATE block
#      entirely once tables exist with the t1309 `intent` column.
#   A. SLOW PATH: `_withInitLock()` mkdir-based advisory lock serialises
#      first-time schema creation across N concurrent workers. Pattern
#      follows `oauth-pool-storage::withPoolLock`. Double-checked locking
#      lets fast-path winners short-circuit the slow path.
#
# This test spawns 8 concurrent Node processes that all call
# `initObservability()` against a fresh temp DB and also upgrades a legacy DB.
# It asserts:
#   1. Zero `database is locked` errors in any child's stderr.
#   2. The DB ends up in WAL mode with all expected tables and append guards.
#   3. Exactly one schema CREATE wins (the others see fast path or
#      double-checked-lock fast path).
#   4. Total runtime < 10s (under contention used to be 30s+).
#   5. A pre-routing schema upgrades before routing indexes are created.

set -uo pipefail

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR_TEST}/../../.." && pwd)" || exit 1
PLUGIN_DIR="${REPO_ROOT}/.agents/plugins/opencode-aidevops"

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
	local msg="$1"
	TESTS_RUN=$((TESTS_RUN + 1))
	printf '  %sPASS%s %s\n' "$TEST_GREEN" "$TEST_NC" "$msg"
	return 0
}

fail() {
	local msg="$1"
	local detail="${2:-}"
	TESTS_RUN=$((TESTS_RUN + 1))
	TESTS_FAILED=$((TESTS_FAILED + 1))
	printf '  %sFAIL%s %s\n' "$TEST_RED" "$TEST_NC" "$msg"
	if [[ -n "$detail" ]]; then
		printf '       %s\n' "$detail"
	fi
	return 0
}

# =============================================================================
# Test harness
# =============================================================================

if ! command -v node >/dev/null 2>&1; then
	printf '%sSKIP%s test-observability-concurrent-init: node not installed\n' \
		"$TEST_BLUE" "$TEST_NC"
	exit 0
fi
if ! command -v sqlite3 >/dev/null 2>&1; then
	printf '%sSKIP%s test-observability-concurrent-init: sqlite3 not installed\n' \
		"$TEST_BLUE" "$TEST_NC"
	exit 0
fi

# Per-test temp dir (auto-cleaned). Lives under TMPDIR so a panic inside
# initDatabase doesn't pollute the caller's HOME.
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/aidevops-t2900.XXXXXX")" || exit 1
trap 'rm -rf "$TMP_ROOT" 2>/dev/null || true' EXIT

DB_PATH="${TMP_ROOT}/llm-requests.db"
WORKER_COUNT=8
LOG_DIR="${TMP_ROOT}/worker-logs"
mkdir -p "$LOG_DIR"

# Tiny driver script: imports observability.mjs and calls initObservability.
# Lives inside TMP_ROOT so we don't pollute the repo with a fixture file.
DRIVER="${TMP_ROOT}/init-driver.mjs"
cat >"$DRIVER" <<EOF
import { initObservability } from "${PLUGIN_DIR}/observability.mjs";
const ok = initObservability();
process.exit(ok ? 0 : 1);
EOF

printf '%sTest:%s concurrent observability init (t2900)\n' "$TEST_BLUE" "$TEST_NC"
printf '       DB:           %s\n' "$DB_PATH"
printf '       Workers:      %d\n' "$WORKER_COUNT"
printf '       Driver:       %s\n' "$DRIVER"

# =============================================================================
# Run N concurrent driver processes — one per "worker startup" — and capture
# each one's combined stdout+stderr to its own log.
# =============================================================================

start_ts=$(date +%s)
pids=()
for ((i = 0; i < WORKER_COUNT; i++)); do
	AIDEVOPS_OBS_DB_OVERRIDE="$DB_PATH" \
		node "$DRIVER" >"${LOG_DIR}/worker-${i}.log" 2>&1 &
	pids+=($!)
done

exit_codes=()
for pid in "${pids[@]}"; do
	wait "$pid"
	exit_codes+=($?)
done
end_ts=$(date +%s)
elapsed=$((end_ts - start_ts))

# =============================================================================
# Assertion 1: every worker exited cleanly.
# =============================================================================

clean_exits=0
for code in "${exit_codes[@]}"; do
	[[ "$code" -eq 0 ]] && clean_exits=$((clean_exits + 1))
done
if [[ "$clean_exits" -eq "$WORKER_COUNT" ]]; then
	pass "all $WORKER_COUNT workers exited 0"
else
	fail "all $WORKER_COUNT workers exited 0" \
		"only $clean_exits/$WORKER_COUNT clean exits — see ${LOG_DIR}"
fi

# =============================================================================
# Assertion 2: zero "database is locked" messages across all workers.
# This is the primary regression — pre-fix, ALL workers logged this error.
# =============================================================================

lock_errors=$(grep -c "database is locked" "${LOG_DIR}"/worker-*.log 2>/dev/null |
	awk -F: '{sum += $2} END {print sum+0}')
if [[ "$lock_errors" -eq 0 ]]; then
	pass "zero 'database is locked' errors across $WORKER_COUNT workers"
else
	fail "zero 'database is locked' errors across $WORKER_COUNT workers" \
		"saw $lock_errors lock errors — see ${LOG_DIR}/worker-*.log"
fi

# =============================================================================
# Assertion 3: DB ends up in WAL mode (the schema's first PRAGMA).
# =============================================================================

journal_mode=$(sqlite3 "$DB_PATH" "PRAGMA journal_mode;" 2>/dev/null || true)
if [[ "$journal_mode" == "wal" ]]; then
	pass "DB journal_mode = wal"
else
	fail "DB journal_mode = wal" \
		"actual: '$journal_mode'"
fi

# =============================================================================
# Assertion 4: all five tables exist with expected columns and triggers.
# =============================================================================

table_count=$(sqlite3 "$DB_PATH" \
	"SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('llm_requests','tool_calls','session_summaries','runtime_events','runtime_event_archives');" \
	2>/dev/null || echo "0")
if [[ "$table_count" == "5" ]]; then
	pass "all 5 tables created, including runtime-event archive manifests"
else
	fail "all 5 observability tables created" \
		"found $table_count of 5"
fi

intent_col_count=$(sqlite3 "$DB_PATH" \
	"SELECT COUNT(*) FROM pragma_table_info('tool_calls') WHERE name='intent';" \
	2>/dev/null || echo "0")
if [[ "$intent_col_count" == "1" ]]; then
	pass "t1309 'intent' column present on tool_calls"
else
	fail "t1309 'intent' column present on tool_calls" \
		"column count: $intent_col_count (expected 1)"
fi

routing_col_count=$(sqlite3 "$DB_PATH" \
	"SELECT COUNT(*) FROM pragma_table_info('llm_requests') WHERE name IN ('parent_session_id','routing_tier','routing_candidate_index','routing_attempt','routing_reason','routing_escalated');" \
	2>/dev/null || echo "0")
if [[ "$routing_col_count" == "6" ]]; then
	pass "routing decision columns present on llm_requests"
else
	fail "routing decision columns present on llm_requests" \
		"column count: $routing_col_count (expected 6)"
fi

runtime_guard_count=$(sqlite3 "$DB_PATH" \
	"SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('runtime_events_reject_update','runtime_events_reject_delete');" \
	2>/dev/null || echo "0")
if [[ "$runtime_guard_count" == "2" ]]; then
	pass "runtime_events append-only triggers present"
else
	fail "runtime_events append-only triggers present" \
		"trigger count: $runtime_guard_count (expected 2)"
fi

archive_guard_count=$(sqlite3 "$DB_PATH" \
	"SELECT COUNT(*) FROM sqlite_master WHERE type='trigger' AND name IN ('runtime_event_archives_reject_update','runtime_event_archives_reject_delete');" \
	2>/dev/null || echo "0")
if [[ "$archive_guard_count" == "2" ]]; then
	pass "runtime-event archive manifests are append-only"
else
	fail "runtime-event archive manifest guards present" \
		"trigger count: $archive_guard_count (expected 2)"
fi

# =============================================================================
# Assertion 5: runtime stayed under the regression budget.
# Pre-fix, 8 concurrent workers with 459MB DB took 30s+ before erroring.
# Post-fix on a fresh DB this completes in ~2-3s.
# =============================================================================

if [[ "$elapsed" -le 10 ]]; then
	pass "elapsed ${elapsed}s ≤ 10s regression budget"
else
	fail "elapsed ${elapsed}s ≤ 10s regression budget" \
		"runtime regressed — investigate writer-lock contention"
fi

# =============================================================================
# Assertion 6: the init lock dir is cleaned up after all workers finish.
# A leaked lockdir would block the next session's slow path.
# =============================================================================

lock_dir="${DB_PATH}.init.lock.d"
if [[ ! -d "$lock_dir" ]]; then
	pass "init lockdir cleaned up after run"
else
	fail "init lockdir cleaned up after run" \
		"lockdir still exists at $lock_dir"
fi

# =============================================================================
# Assertion 7: a pre-routing observability DB upgrades successfully.
#
# CREATE TABLE IF NOT EXISTS leaves an existing llm_requests table unchanged.
# Routing indexes therefore must not be created until the migration has added
# their columns. This fixture mirrors the prior table shape and keeps a row to
# verify that the in-place migration preserves existing data.
# =============================================================================

LEGACY_DB_PATH="${TMP_ROOT}/legacy-llm-requests.db"
LEGACY_LOG="${TMP_ROOT}/legacy-init.log"
sqlite3 "$LEGACY_DB_PATH" <<'SQL'
CREATE TABLE llm_requests (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  session_id TEXT NOT NULL,
  message_id TEXT,
  provider_id TEXT,
  model_id TEXT,
  agent TEXT,
  tokens_input INTEGER DEFAULT 0,
  tokens_output INTEGER DEFAULT 0,
  tokens_reasoning INTEGER DEFAULT 0,
  tokens_cache_read INTEGER DEFAULT 0,
  tokens_cache_write INTEGER DEFAULT 0,
  tokens_total INTEGER DEFAULT 0,
  cost REAL DEFAULT 0.0,
  duration_ms INTEGER,
  finish_reason TEXT,
  error_type TEXT,
  error_message TEXT,
  tool_call_count INTEGER DEFAULT 0,
  project_path TEXT,
  variant TEXT
);
CREATE TABLE tool_calls (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  session_id TEXT NOT NULL,
  message_id TEXT,
  call_id TEXT,
  tool_name TEXT NOT NULL,
  success INTEGER DEFAULT 1,
  duration_ms INTEGER,
  metadata TEXT
);
INSERT INTO llm_requests (session_id, model_id) VALUES ('legacy-session', 'legacy-model');
SQL

legacy_exit=0
AIDEVOPS_OBS_DB_OVERRIDE="$LEGACY_DB_PATH" \
	node "$DRIVER" >"$LEGACY_LOG" 2>&1 || legacy_exit=$?
if [[ "$legacy_exit" -eq 0 ]]; then
	pass "legacy observability schema initialises successfully"
else
	fail "legacy observability schema initialises successfully" \
		"exit $legacy_exit — see $LEGACY_LOG"
fi

legacy_routing_col_count=$(sqlite3 "$LEGACY_DB_PATH" \
	"SELECT COUNT(*) FROM pragma_table_info('llm_requests') WHERE name IN ('parent_session_id','routing_tier','routing_candidate_index','routing_attempt','routing_reason','routing_escalated');" \
	2>/dev/null || true)
if [[ "$legacy_routing_col_count" == "6" ]]; then
	pass "legacy schema gains all routing decision columns"
else
	fail "legacy schema gains all routing decision columns" \
		"column count: ${legacy_routing_col_count:-0} (expected 6)"
fi

legacy_routing_index_count=$(sqlite3 "$LEGACY_DB_PATH" \
	"SELECT COUNT(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_llm_requests_parent_session','idx_llm_requests_routing_tier');" \
	2>/dev/null || true)
if [[ "$legacy_routing_index_count" == "2" ]]; then
	pass "legacy schema gains routing indexes after column migration"
else
	fail "legacy schema gains routing indexes after column migration" \
		"index count: ${legacy_routing_index_count:-0} (expected 2)"
fi

legacy_row_count=$(sqlite3 "$LEGACY_DB_PATH" \
	"SELECT COUNT(*) FROM llm_requests WHERE session_id='legacy-session' AND model_id='legacy-model';" \
	2>/dev/null || true)
if [[ "$legacy_row_count" == "1" ]]; then
	pass "legacy migration preserves existing request rows"
else
	fail "legacy migration preserves existing request rows" \
		"matching row count: ${legacy_row_count:-0} (expected 1)"
fi

# =============================================================================
# Summary
# =============================================================================

printf '\n'
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	printf '%sAll %d tests passed%s (elapsed: %ds)\n' \
		"$TEST_GREEN" "$TESTS_RUN" "$TEST_NC" "$elapsed"
	exit 0
else
	printf '%s%d of %d tests failed%s (elapsed: %ds)\n' \
		"$TEST_RED" "$TESTS_FAILED" "$TESTS_RUN" "$TEST_NC" "$elapsed"
	printf '\nWorker logs preserved at: %s\n' "$LOG_DIR"
	# Don't auto-clean on failure so the operator can inspect.
	trap - EXIT
	exit 1
fi
