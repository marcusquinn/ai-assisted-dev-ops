#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# Tests for opencode-db-maintenance-helper.sh (t2174).
#
# Strategy: build a synthetic opencode-shaped SQLite DB in a tmp dir,
# point the helper at it via XDG_DATA_HOME, and assert each subcommand
# behaves correctly. No real opencode install is touched.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../opencode-db-maintenance-helper.sh"
# shellcheck source=lib/test-helpers.sh
source "${SCRIPT_DIR}/lib/test-helpers.sh"

if [[ ! -x "$HELPER" ]]; then
	echo "FAIL: helper not executable at $HELPER"
	exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
	echo "SKIP: sqlite3 not available"
	exit 0
fi

PASS=0
FAIL=0

_pass() {
	PASS=$((PASS + 1))
	printf '  \033[0;32mPASS\033[0m %s\n' "$1"
	return 0
}
_fail() {
	FAIL=$((FAIL + 1))
	printf '  \033[0;31mFAIL\033[0m %s\n' "$1"
	return 0
}

# -----------------------------------------------------------------------------
# Sandbox setup
# -----------------------------------------------------------------------------

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

export XDG_DATA_HOME="$SANDBOX/data"

OPENCODE_DIR="$XDG_DATA_HOME/opencode"
mkdir -p "$OPENCODE_DIR"

# Route state to sandbox so tests don't touch real state
AIDEVOPS_WS="$SANDBOX/aidevops-ws"
mkdir -p "$AIDEVOPS_WS"

# The helper resolves STATE_DIR from $HOME — redirect HOME for the duration
# of each invocation.
_run_helper() {
	HOME="$SANDBOX/fakehome" "$HELPER" "$@"
	return $?
}

_make_opencode_db() {
	# Build an opencode-shaped DB with a few thousand rows for fragmentation
	sqlite3 "$OPENCODE_DIR/opencode.db" <<'SQL'
PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
CREATE TABLE session (
  id text PRIMARY KEY,
  directory text,
  title text,
  time_created integer
);
CREATE TABLE message (
  id text PRIMARY KEY,
  session_id text NOT NULL,
  time_created integer NOT NULL,
  time_updated integer NOT NULL,
  data text NOT NULL
);
CREATE INDEX message_session_idx ON message(session_id, time_created, id);
INSERT INTO session VALUES ('ses1', '/tmp', 'test', 0);
SQL

	# Insert+delete rows to create freelist pages (fragmentation)
	local i
	local payload
	for i in $(seq 1 120); do
		payload=$(printf 'payload-%04d-%01024d' "$i" 0)
		sqlite3 "$OPENCODE_DIR/opencode.db" \
			"INSERT INTO message VALUES ('msg$i', 'ses1', $i, $i, '$payload');" 2>/dev/null
	done
	sqlite3 "$OPENCODE_DIR/opencode.db" "DELETE FROM message WHERE CAST(substr(id, 4) AS INTEGER) % 2 = 0;" 2>/dev/null
	return 0
}

# -----------------------------------------------------------------------------
# Test 1: help returns 0 and shows subcommand list
# -----------------------------------------------------------------------------

out=$(_run_helper help 2>&1)
if grep -q "check" <<<"$out" && grep -q "maintain" <<<"$out" && grep -q "auto" <<<"$out" && grep -q "notice" <<<"$out"; then
	_pass "help lists all subcommands"
else
	_fail "help output missing subcommands"
fi

# -----------------------------------------------------------------------------
# Test 1b: notice is quiet when opencode not installed
# -----------------------------------------------------------------------------

set +e
out=$(_run_helper notice 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && [[ -z "$out" ]]; then
	_pass "notice is quiet when opencode is not installed"
else
	_fail "notice should be quiet with no DB (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 2: check returns 0 when opencode not installed (no-op path)
# -----------------------------------------------------------------------------

# No DB yet → should report no-op cleanly
set +e
_run_helper check >/dev/null 2>&1
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
	_pass "check returns 0 when opencode not installed"
else
	_fail "check returned $rc (expected 0) when opencode not installed"
fi

# -----------------------------------------------------------------------------
# Test 3: auto returns 0 silently when opencode not installed
# -----------------------------------------------------------------------------

set +e
out=$(_run_helper auto 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
	_pass "auto returns 0 when opencode not installed"
else
	_fail "auto returned $rc (expected 0) with no DB — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 4: Create the synthetic DB, then report shows stats
# -----------------------------------------------------------------------------

_make_opencode_db

set +e
out=$(_run_helper report 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "OpenCode DB Report" <<<"$out" && grep -q "DB size:" <<<"$out"; then
	_pass "report shows DB stats for synthetic DB"
else
	_fail "report failed or output missing stats (rc=$rc)"
fi

# -----------------------------------------------------------------------------
# Test 5: maintain succeeds on synthetic DB
# -----------------------------------------------------------------------------
# Note: --force is used because the test host may have real opencode
# processes running. The sandbox DB is separate (XDG_DATA_HOME), so
# --force here only waives the *process count* check, not any real risk.

# Lower the fragmentation threshold so VACUUM is exercised on the synthetic DB.
set +e
out=$(VACUUM_FREELIST_THRESHOLD=0.01 _run_helper maintain --force 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "Step 3/3: VACUUM (" <<<"$out" && grep -q "Maintenance complete" <<<"$out"; then
	_pass "maintain succeeds on synthetic DB"
else
	_fail "maintain failed (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 5b: compact DB is not vacuumed solely because it exceeds the size marker
# -----------------------------------------------------------------------------

set +e
out=$(VACUUM_FREELIST_THRESHOLD=0.99 FORCE_VACUUM_SIZE_MB=0 _run_helper maintain --force 2>&1)
rc=$?
set -e
state_file="$SANDBOX/fakehome/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json"
if [[ "$rc" -eq 0 ]] && grep -q "VACUUM skipped (low fragmentation" <<<"$out" &&
	grep -q '"outcome": "success"' "$state_file" &&
	grep -q '"vacuum_ran": false' "$state_file"; then
	_pass "compact DB is not vacuumed solely because it is large"
else
	_fail "compact DB unexpectedly selected VACUUM (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 5c: insufficient or unknown capacity safely defers VACUUM
# -----------------------------------------------------------------------------

capacity_bin="$SANDBOX/capacity-bin"
mkdir -p "$capacity_bin"
cat >"$capacity_bin/df" <<'MOCK_DF_LOW'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' 'mock 1000 999 1 100% /'
exit 0
MOCK_DF_LOW
chmod +x "$capacity_bin/df"

set +e
out=$(PATH="$capacity_bin:$PATH" VACUUM_FREELIST_THRESHOLD=0 _run_helper maintain --force 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "VACUUM deferred (insufficient-capacity" <<<"$out" &&
	grep -q "Maintenance deferred after safe preliminary steps" <<<"$out" &&
	grep -q '"outcome": "deferred"' "$state_file" &&
	grep -q '"vacuum_deferred": true' "$state_file" &&
	grep -q '"vacuum_ran": false' "$state_file"; then
	_pass "insufficient capacity defers VACUUM without reporting success"
else
	_fail "insufficient capacity did not defer VACUUM safely (rc=$rc) — output: $out"
fi

cat >"$capacity_bin/df" <<'MOCK_DF_UNKNOWN'
#!/usr/bin/env bash
exit 1
MOCK_DF_UNKNOWN
chmod +x "$capacity_bin/df"

set +e
out=$(PATH="$capacity_bin:$PATH" VACUUM_FREELIST_THRESHOLD=0 _run_helper maintain --force 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "VACUUM deferred (capacity-unknown" <<<"$out" &&
	grep -q '"outcome": "deferred"' "$state_file" &&
	grep -q '"vacuum_ran": false' "$state_file"; then
	_pass "unknown capacity fails closed before VACUUM"
else
	_fail "unknown capacity did not fail closed (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 5d: attempted VACUUM failure remains a partial non-success outcome
# -----------------------------------------------------------------------------

cat >"$capacity_bin/df" <<'MOCK_DF_HIGH'
#!/usr/bin/env bash
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
printf '%s\n' 'mock 1000000000 1 999999999 1% /'
exit 0
MOCK_DF_HIGH
cat >"$capacity_bin/sqlite3" <<'MOCK_SQLITE'
#!/usr/bin/env bash
last_arg=""
for candidate in "$@"; do
	last_arg="$candidate"
done
if [[ "$last_arg" == "VACUUM;" ]]; then
	printf '%s\n' 'database or disk is full' >&2
	exit 1
fi
exec "$REAL_SQLITE3" "$@"
MOCK_SQLITE
chmod +x "$capacity_bin/df" "$capacity_bin/sqlite3"
real_sqlite3=$(command -v sqlite3)

set +e
out=$(PATH="$capacity_bin:$PATH" REAL_SQLITE3="$real_sqlite3" VACUUM_FREELIST_THRESHOLD=0 _run_helper maintain --force 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 10 ]] && grep -q "VACUUM failed: database or disk is full" <<<"$out" &&
	grep -q "Maintenance partially completed" <<<"$out" &&
	grep -q '"outcome": "partial"' "$state_file" &&
	grep -q '"vacuum_ran": true' "$state_file"; then
	_pass "failed VACUUM remains a partial non-success outcome"
else
	_fail "failed VACUUM outcome was inaccurate (rc=$rc) — output: $out"
fi
rm -rf "$capacity_bin"

# Restore a successful compact state for the existing notice/throttle fixtures.
VACUUM_FREELIST_THRESHOLD=0.99 _run_helper maintain --force >/dev/null

# -----------------------------------------------------------------------------
# Test 6: state file is written after maintain
# -----------------------------------------------------------------------------

if [[ -f "$SANDBOX/fakehome/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json" ]]; then
	_pass "state file written after maintain"
	if grep -q '"outcome":' "$SANDBOX/fakehome/.aidevops/.agent-workspace/work/opencode-maintenance/last-run.json"; then
		_pass "state file contains outcome field"
	else
		_fail "state file missing outcome field"
	fi
else
	_fail "state file not written"
fi

# -----------------------------------------------------------------------------
# Test 7: auto throttles when last run is recent
# -----------------------------------------------------------------------------

# Immediately re-run auto — should be throttled (last-run.json just written).
# Throttle check runs BEFORE the process-count check, so real opencode
# processes don't block the throttle path.
set +e
out=$(_run_helper auto 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -qiE "throttl|skipping" <<<"$out"; then
	_pass "auto throttles when last run is recent"
else
	_fail "auto did not throttle (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 8: unknown subcommand returns 1 with help
# -----------------------------------------------------------------------------

set +e
out=$(_run_helper bogus-subcmd 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 1 ]] && grep -q "Unknown subcommand" <<<"$out"; then
	_pass "unknown subcommand returns 1 with error"
else
	_fail "unknown subcommand behaviour wrong (rc=$rc)"
fi

# -----------------------------------------------------------------------------
# Test 9: r913 is registered in core-routines.sh
# -----------------------------------------------------------------------------

CORE_ROUTINES="${SCRIPT_DIR}/../routines/core-routines.sh"
if [[ -f "$CORE_ROUTINES" ]]; then
	# shellcheck disable=SC1090
	if (source "$CORE_ROUTINES" && get_core_routine_entries | grep -q "^r913|"); then
		_pass "r913 registered in core-routines.sh get_core_routine_entries"
	else
		_fail "r913 not in get_core_routine_entries output"
	fi

	# shellcheck disable=SC1090
	if (source "$CORE_ROUTINES" && declare -f describe_r913 >/dev/null); then
		_pass "describe_r913 function defined"
	else
		_fail "describe_r913 function not defined"
	fi
else
	_fail "core-routines.sh not found at $CORE_ROUTINES"
fi

# -----------------------------------------------------------------------------
# Test 10: report shows WAL status section when WAL_LARGE_THRESHOLD_MB=0
# -----------------------------------------------------------------------------
# Setting the threshold to 0 forces the WAL status code path regardless of
# actual WAL file size, without touching the real opencode.db.

set +e
out=$(WAL_LARGE_THRESHOLD_MB=0 _run_helper report 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -qiE "WAL status:|WAL size:" <<<"$out"; then
	_pass "report shows WAL status section when WAL_LARGE_THRESHOLD_MB=0"
else
	_fail "report missing WAL status section (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 10b: report identifies compact-but-large DBs as retained live data
# -----------------------------------------------------------------------------

set +e
out=$(FORCE_VACUUM_SIZE_MB=0 WAL_LARGE_THRESHOLD_MB=999 _run_helper report 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "compact but large" <<<"$out" && grep -q "Re-running maintenance-window is unlikely" <<<"$out"; then
	_pass "report explains compact-but-large DBs"
else
	_fail "report missing compact-but-large note (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 11: check shows WAL info when WAL_LARGE_THRESHOLD_MB=0
# -----------------------------------------------------------------------------

set +e
out=$(WAL_LARGE_THRESHOLD_MB=0 _run_helper check 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -qiE "WAL:" <<<"$out"; then
	_pass "check shows WAL info when WAL_LARGE_THRESHOLD_MB=0"
else
	_fail "check missing WAL info (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 11b: notice warns when WAL threshold says maintenance is due
# -----------------------------------------------------------------------------

set +e
out=$(WAL_LARGE_THRESHOLD_MB=0 _run_helper notice 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "\[OPENCODE MAINTENANCE\]" <<<"$out" && grep -q "aidevops opencode-db maintenance-window" <<<"$out"; then
	_pass "notice warns when maintenance is due"
else
	_fail "notice missing due warning (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 11c: notice warns about scheduled disruptive maintenance-window mode
# -----------------------------------------------------------------------------

set +e
out=$(OPENCODE_DB_MAINTENANCE_MODE=maintenance-window OPENCODE_DB_MAINTENANCE_HOUR=3 OPENCODE_DB_MAINTENANCE_MINUTE=30 _run_helper notice 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "Sun 03:30" <<<"$out" && grep -q "pauses pulse/headless workers" <<<"$out"; then
	_pass "notice warns about scheduled maintenance-window pause"
else
	_fail "notice missing scheduled maintenance-window warning (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 11d: notice rewords size-only trigger after recent compact success
# -----------------------------------------------------------------------------

set +e
out=$(FORCE_VACUUM_SIZE_MB=0 WAL_LARGE_THRESHOLD_MB=999 _run_helper notice 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "Compact but large" <<<"$out" && ! grep -q "Run aidevops opencode-db maintenance-window" <<<"$out"; then
	_pass "notice does not recommend repeat maintenance for compact large DB"
else
	_fail "notice should reword compact large DB (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 11d.1: invalid integer environment thresholds fall back safely
# -----------------------------------------------------------------------------

set +e
out=$(FORCE_VACUUM_SIZE_MB=bogus WAL_LARGE_THRESHOLD_MB=bogus AUTO_MIN_SECONDS_BETWEEN=bogus _run_helper notice 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && ! grep -q "integer expression expected" <<<"$out" && ! grep -q "syntax error" <<<"$out"; then
	_pass "notice handles invalid integer threshold environment values"
else
	_fail "notice should ignore invalid integer threshold environment values (rc=$rc) — output: $out"
fi

set +e
out=$(FORCE_VACUUM_SIZE_MB=08 WAL_LARGE_THRESHOLD_MB=09 AUTO_MIN_SECONDS_BETWEEN=000001 _run_helper notice 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && ! grep -q "value too great for base" <<<"$out" && ! grep -q "syntax error" <<<"$out"; then
	_pass "notice normalizes leading-zero integer threshold environment values"
else
	_fail "notice should normalize leading-zero integer thresholds (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 11e: notice still recommends maintenance when free-page threshold is due
# -----------------------------------------------------------------------------

set +e
out=$(FORCE_VACUUM_SIZE_MB=0 VACUUM_FREELIST_THRESHOLD=0 WAL_LARGE_THRESHOLD_MB=999 _run_helper notice 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "Recommended:" <<<"$out" && grep -q "maintenance-window" <<<"$out"; then
	_pass "notice still recommends maintenance when freelist threshold is due"
else
	_fail "notice should recommend when freelist threshold is due (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 12: WAL report does not error when WAL file absent (no-op path)
# -----------------------------------------------------------------------------

# Remove the WAL to test the absent-WAL path
rm -f "$OPENCODE_DIR/opencode.db-wal" "$OPENCODE_DIR/opencode.db-shm"

set +e
out=$(WAL_LARGE_THRESHOLD_MB=0 _run_helper report 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]]; then
	_pass "report exits 0 cleanly when WAL file is absent"
else
	_fail "report failed (rc=$rc) when WAL absent — output: $out"
fi

# Recreate the WAL-capable DB after the absent-WAL test for maintenance-window.
rm -f "$OPENCODE_DIR/opencode.db"
_make_opencode_db

# -----------------------------------------------------------------------------
# Test 13: maintenance-window restores pulse through mocked lifecycle helper
# -----------------------------------------------------------------------------

mock_bin="$SANDBOX/mock-bin"
mkdir -p "$mock_bin"
mock_pulse_log="$SANDBOX/pulse-lifecycle.log"
mock_archive_log="$SANDBOX/archive.log"
cat >"$mock_bin/pulse-lifecycle-helper.sh" <<'MOCK_PULSE'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$MOCK_PULSE_LOG"
exit 0
MOCK_PULSE
chmod +x "$mock_bin/pulse-lifecycle-helper.sh"
cat >"$mock_bin/opencode-db-archive.sh" <<'MOCK_ARCHIVE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MOCK_ARCHIVE_LOG"
exit 0
MOCK_ARCHIVE
chmod +x "$mock_bin/opencode-db-archive.sh"

set +e
out=$(PATH="$mock_bin:$PATH" MOCK_PULSE_LOG="$mock_pulse_log" MOCK_ARCHIVE_LOG="$mock_archive_log" \
	PULSE_LIFECYCLE_HELPER="$mock_bin/pulse-lifecycle-helper.sh" \
	OPENCODE_DB_ARCHIVE_HELPER="$mock_bin/opencode-db-archive.sh" \
	VACUUM_FREELIST_THRESHOLD=0.01 FORCE_VACUUM_SIZE_MB=0 \
	_run_helper maintenance-window --force-opencode --keep-sessions 123 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q '^stop$' "$mock_pulse_log" && grep -q '^start$' "$mock_pulse_log" && grep -q -- '--retention-days 30' "$mock_archive_log" && grep -q -- '--keep-sessions 123' "$mock_archive_log"; then
	_pass "maintenance-window stops pulse, archives, maintains, and restarts pulse"
else
	_fail "maintenance-window mocked lifecycle failed (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 14: maintenance-window restarts pulse on early active-holder exit
# -----------------------------------------------------------------------------

cat >"$mock_bin/pgrep" <<'MOCK_PGREP'
#!/usr/bin/env bash
printf '%s\n' '12345'
exit 0
MOCK_PGREP
chmod +x "$mock_bin/pgrep"
: >"$mock_pulse_log"
: >"$mock_archive_log"

set +e
out=$(PATH="$mock_bin:$PATH" MOCK_PULSE_LOG="$mock_pulse_log" MOCK_ARCHIVE_LOG="$mock_archive_log" \
	PULSE_LIFECYCLE_HELPER="$mock_bin/pulse-lifecycle-helper.sh" \
	OPENCODE_DB_ARCHIVE_HELPER="$mock_bin/opencode-db-archive.sh" \
	_run_helper maintenance-window --keep-sessions 123 2>&1)
rc=$?
set -e
rm -f "$mock_bin/pgrep"
if [[ "$rc" -eq 2 ]] && grep -q '^stop$' "$mock_pulse_log" && grep -q '^start$' "$mock_pulse_log" && [[ ! -s "$mock_archive_log" ]]; then
	_pass "maintenance-window restarts pulse after active-holder early return"
else
	_fail "maintenance-window early-return cleanup failed (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 14b: deployed sibling lifecycle helper is preferred over PATH
# -----------------------------------------------------------------------------

deployed_scripts="$SANDBOX/deployed-scripts"
mkdir -p "$deployed_scripts"
cp "$HELPER" "$deployed_scripts/opencode-db-maintenance-helper.sh"
_test_copy_shared_deps "${SCRIPT_DIR}/.." "$deployed_scripts"
sibling_pulse_log="$SANDBOX/sibling-pulse-lifecycle.log"
cat >"$deployed_scripts/pulse-lifecycle-helper.sh" <<'MOCK_SIBLING_PULSE'
#!/usr/bin/env bash
printf '%s\n' "$1" >>"$SIBLING_PULSE_LOG"
exit 0
MOCK_SIBLING_PULSE
chmod +x "$deployed_scripts/opencode-db-maintenance-helper.sh" "$deployed_scripts/pulse-lifecycle-helper.sh"
: >"$mock_pulse_log"
: >"$sibling_pulse_log"

set +e
out=$(env -u PULSE_LIFECYCLE_HELPER PATH="$mock_bin:$PATH" HOME="$SANDBOX/fakehome" \
	SIBLING_PULSE_LOG="$sibling_pulse_log" MOCK_PULSE_LOG="$mock_pulse_log" \
	OPENCODE_DB_ARCHIVE_HELPER="$mock_bin/opencode-db-archive.sh" \
	"$deployed_scripts/opencode-db-maintenance-helper.sh" maintenance-window --force-opencode --skip-archive 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q '^stop$' "$sibling_pulse_log" && grep -q '^start$' "$sibling_pulse_log" && [[ ! -s "$mock_pulse_log" ]]; then
	_pass "maintenance-window prefers deployed sibling lifecycle helper over PATH"
else
	_fail "maintenance-window did not prefer sibling lifecycle helper (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 14c: explicit lifecycle helper override takes precedence over sibling
# -----------------------------------------------------------------------------

: >"$mock_pulse_log"
: >"$sibling_pulse_log"
set +e
out=$(PATH="$mock_bin:$PATH" HOME="$SANDBOX/fakehome" \
	PULSE_LIFECYCLE_HELPER="$mock_bin/pulse-lifecycle-helper.sh" \
	SIBLING_PULSE_LOG="$sibling_pulse_log" MOCK_PULSE_LOG="$mock_pulse_log" \
	OPENCODE_DB_ARCHIVE_HELPER="$mock_bin/opencode-db-archive.sh" \
	"$deployed_scripts/opencode-db-maintenance-helper.sh" maintenance-window --force-opencode --skip-archive 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q '^stop$' "$mock_pulse_log" && grep -q '^start$' "$mock_pulse_log" && [[ ! -s "$sibling_pulse_log" ]]; then
	_pass "explicit lifecycle helper override takes precedence over sibling"
else
	_fail "explicit lifecycle helper override was not preserved (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 14d: genuinely missing lifecycle helper retains safe warning fallback
# -----------------------------------------------------------------------------

missing_scripts="$SANDBOX/missing-scripts"
mkdir -p "$missing_scripts"
cp "$HELPER" "$missing_scripts/opencode-db-maintenance-helper.sh"
_test_copy_shared_deps "${SCRIPT_DIR}/.." "$missing_scripts"
chmod +x "$missing_scripts/opencode-db-maintenance-helper.sh"
sqlite_dir=$(dirname "$(command -v sqlite3)")
set +e
out=$(env -u PULSE_LIFECYCLE_HELPER PATH="$sqlite_dir:/usr/bin:/bin" HOME="$SANDBOX/fakehome" \
	OPENCODE_DB_ARCHIVE_HELPER="$mock_bin/opencode-db-archive.sh" \
	"$missing_scripts/opencode-db-maintenance-helper.sh" maintenance-window --force-opencode --skip-archive 2>&1)
rc=$?
set -e
if [[ "$rc" -eq 0 ]] && grep -q "pulse lifecycle helper not found; skipping pulse stop/start" <<<"$out"; then
	_pass "missing lifecycle helper retains warning and safe fallback"
else
	_fail "missing lifecycle helper fallback changed (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Test 15: threshold parsing does not execute awk code from environment
# -----------------------------------------------------------------------------

injection_marker="$SANDBOX/awk-threshold-injection"
threshold_payload="0); system(\"touch ${injection_marker}\"); (0"
set +e
out=$(VACUUM_FREELIST_THRESHOLD="$threshold_payload" FORCE_VACUUM_SIZE_MB=0 WAL_LARGE_THRESHOLD_MB=999 _run_helper notice 2>&1)
rc=$?
set -e
if [[ ! -e "$injection_marker" ]]; then
	_pass "freelist threshold environment value is not executable awk code"
else
	_fail "freelist threshold environment value executed code (rc=$rc) — output: $out"
fi

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------

echo
printf 'Results: %d passed, %d failed\n' "$PASS" "$FAIL"
if [[ "$FAIL" -gt 0 ]]; then
	exit 1
fi
exit 0
