#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
#
# test-runtime-audit-detectors.sh — Structural tests for t3072 runtime-audit
# detectors and orchestrator.
#
# Each detector is exercised twice: once with a fixture that should fire
# (return 1 + JSON), once with a fixture that should NOT fire (return 0).
# The orchestrator is exercised in --dry-run --only mode against the
# fixture so end-to-end JSON parsing is covered.
#
# Tests are pure-shell — no GitHub API, no pulse state mutation.

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

assert_rc() {
	local label="$1" expected="$2" actual="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ "$expected" == "$actual" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected rc=$expected, got rc=$actual"
	fi
	return 0
}

assert_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected to find: $(printf '%q' "$needle")"
		echo "  in: $(printf '%q' "${haystack:0:200}")"
	fi
	return 0
}

assert_not_contains() {
	local label="$1" needle="$2" haystack="$3"
	TESTS_RUN=$((TESTS_RUN + 1))
	if printf '%s' "$haystack" | grep -qF -- "$needle" 2>/dev/null; then
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected not to find: $(printf '%q' "$needle")"
	else
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	fi
	return 0
}

assert_empty() {
	local label="$1" value="$2"
	TESTS_RUN=$((TESTS_RUN + 1))
	if [[ -z "$value" ]]; then
		echo "${TEST_GREEN}PASS${TEST_NC}: $label"
	else
		TESTS_FAILED=$((TESTS_FAILED + 1))
		echo "${TEST_RED}FAIL${TEST_NC}: $label"
		echo "  expected empty, got: $(printf '%q' "${value:0:200}")"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RULES_DIR="$SCRIPT_DIR/runtime-audit-rules"
ORCHESTRATOR="$SCRIPT_DIR/runtime-health-audit-helper.sh"
SHARED_CONSTANTS="$SCRIPT_DIR/shared-constants.sh"

if [[ ! -d "$RULES_DIR" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: rules dir not found: $RULES_DIR"
	exit 1
fi
if [[ ! -x "$ORCHESTRATOR" ]]; then
	echo "${TEST_RED}FATAL${TEST_NC}: orchestrator not executable: $ORCHESTRATOR"
	exit 1
fi

# Tmp dir per test run; cleaned up on exit
TMPDIR_TEST=$(mktemp -d /tmp/runtime-audit-test.XXXXXX)
trap 'rm -rf "$TMPDIR_TEST"' EXIT

# Helper: run a detector in a clean subshell with an env block, capture
# stdout and rc.
_run_detector() {
	local detector_file="$1"
	shift
	local out
	local rc=0
	# shellcheck disable=SC2068  # passing through env assignments
	out=$(env "$@" bash -c "
		set -u
		source '$SHARED_CONSTANTS'
		source '$detector_file'
		runtime_audit_check
	" 2>/dev/null) || rc=$?
	printf '%s\n' "$out"
	return "$rc"
}

echo "${TEST_BLUE}=== t3072: runtime-audit detector tests ===${TEST_NC}"
echo ""

# ---------------------------------------------------------------------------
# Test 1: counter-trend-delta
# ---------------------------------------------------------------------------
echo "--- Section 1: counter-trend-delta ---"

STATS_FIRING="$TMPDIR_TEST/stats-firing.json"
cat >"$STATS_FIRING" <<'JSON'
{
  "counters": {
    "test_regressed": [850, 901, 920, 950, 970, 990, 999],
    "test_steady":    [810, 820, 910, 920, 930, 950, 970]
  }
}
JSON

# now=1000, window=100
# recent [900..1000]: regressed=6, steady=5
# prior  [800..900):  regressed=1, steady=2
# regressed: 6 >= 1*2 ✓ → fires
# steady:    5 >= 2*2 = 4 ✓ → also fires (more conservative test would
# pick mult=3, but mult=2 with min_baseline=1 keeps the fixture compact)
out=$(_run_detector "$RULES_DIR/counter-trend-delta.sh" \
	"STATS_FILE=$STATS_FIRING" \
	"NOW_EPOCH=1000" \
	"WINDOW_SECONDS=100" \
	"REGRESSION_MULT=2" \
	"MIN_BASELINE=1") && rc=0 || rc=$?
assert_rc "1.1 firing fixture returns 1" "1" "$rc"
assert_contains "1.2 firing JSON has correct id" '"id": "counter-trend-delta"' "$out"
assert_contains "1.3 firing JSON references regressed counter" "test_regressed" "$out"
assert_contains "1.4 firing body has marker" 'detector=counter-trend-delta' "$out"

# Clean fixture: only steady counter, no regression
STATS_CLEAN="$TMPDIR_TEST/stats-clean.json"
cat >"$STATS_CLEAN" <<'JSON'
{
  "counters": {
    "test_steady": [810, 820, 910, 920, 930]
  }
}
JSON

out=$(_run_detector "$RULES_DIR/counter-trend-delta.sh" \
	"STATS_FILE=$STATS_CLEAN" \
	"NOW_EPOCH=1000" \
	"WINDOW_SECONDS=100" \
	"REGRESSION_MULT=10" \
	"MIN_BASELINE=10") && rc=0 || rc=$?
assert_rc "1.5 clean fixture returns 0" "0" "$rc"
assert_empty "1.6 clean fixture emits no output" "$out"

# Missing stats file → no-op (return 0, no output)
out=$(_run_detector "$RULES_DIR/counter-trend-delta.sh" \
	"STATS_FILE=/nonexistent/path/stats.json") && rc=0 || rc=$?
assert_rc "1.7 missing stats file returns 0" "0" "$rc"

# ---------------------------------------------------------------------------
# Test 2: process-count-anomaly
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 2: process-count-anomaly ---"

PS_FIRING=$(printf '%s\n' \
	"  101 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
	"  102 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
	"  103 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
	"  104 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
	"  105 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
	"  106 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
	"  107 /usr/bin/some-other-process")

out=$(_run_detector "$RULES_DIR/process-count-anomaly.sh" \
	"PS_OUTPUT_OVERRIDE=$PS_FIRING" \
	"LEAK_THRESHOLD=3" \
	"PROC_PATTERN=pulse-wrapper.sh") && rc=0 || rc=$?
assert_rc "2.1 firing fixture returns 1" "1" "$rc"
assert_contains "2.2 firing body has correct id" '"id": "process-count-anomaly"' "$out"
assert_contains "2.3 firing title cites count" "count anomaly (6 > 3)" "$out"
assert_contains "2.4 firing body has marker" 'detector=process-count-anomaly' "$out"

# Clean fixture: 2 matches, threshold 5 → no-op
PS_CLEAN=$(printf '%s\n' \
	"  101 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
	"  102 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh")
out=$(_run_detector "$RULES_DIR/process-count-anomaly.sh" \
	"PS_OUTPUT_OVERRIDE=$PS_CLEAN" \
	"LEAK_THRESHOLD=5" \
	"PROC_PATTERN=pulse-wrapper.sh") && rc=0 || rc=$?
assert_rc "2.5 below-threshold fixture returns 0" "0" "$rc"
assert_empty "2.6 below-threshold emits no output" "$out"

# Live mode: background stage subshells inherit the pulse-wrapper argv but
# have the root pulse process as their parent, so they must not count as
# duplicate top-level instances.
FAKE_PS_DIR="$TMPDIR_TEST/fake-ps-bin"
mkdir -p "$FAKE_PS_DIR"
cat >"$FAKE_PS_DIR/ps" <<'FAKE_PS'
#!/usr/bin/env bash
if [[ "$*" == "-ax -o pid=,command=" ]]; then
	printf '%s\n' \
		"  101 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
		"  102 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
		"  103 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
		"  104 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
		"  105 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh" \
		"  106 /bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh"
	exit 0
fi
if [[ "$4" == "ppid=" ]]; then
	if [[ "$2" == "101" ]]; then
		printf '1\n'
	else
		printf '101\n'
	fi
	exit 0
fi
if [[ "$4" == "command=" ]]; then
	if [[ "$2" == "101" ]]; then
		printf '/bin/bash /Users/x/.aidevops/agents/scripts/pulse-wrapper.sh\n'
	else
		printf '/sbin/init\n'
	fi
	exit 0
fi
exit 1
FAKE_PS
chmod +x "$FAKE_PS_DIR/ps"
out=$(_run_detector "$RULES_DIR/process-count-anomaly.sh" \
	"PATH=$FAKE_PS_DIR:/usr/bin:/bin" \
	"LEAK_THRESHOLD=3" \
	"PROC_PATTERN=pulse-wrapper.sh") && rc=0 || rc=$?
assert_rc "2.7 live mode excludes pulse-wrapper child subshells" "0" "$rc"
assert_empty "2.8 filtered live mode emits no output" "$out"

# ---------------------------------------------------------------------------
# Test 3: deployed-vs-source-mtime-drift
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 3: deployed-vs-source-mtime-drift ---"

DRIFT_DEPLOYED="$TMPDIR_TEST/deployed"
DRIFT_SOURCE="$TMPDIR_TEST/source"
mkdir -p "$DRIFT_DEPLOYED" "$DRIFT_SOURCE"

# pulse-wrapper.sh: deployed touched 3 days ago, source touched 1 minute ago
# → drift = ~3 days = 259200 > DRIFT_SECONDS (3600 in this test)
echo "deployed-content" >"$DRIFT_DEPLOYED/pulse-wrapper.sh"
echo "source-content" >"$DRIFT_SOURCE/pulse-wrapper.sh"

# Use touch -t to set deployed mtime in the past
# Format: [[CC]YY]MMDDhhmm[.SS]
# Pick a fixed reference point so the test is deterministic regardless of
# wall-clock at runtime: deployed = 200 days ago, source = now
old_ts=$(date -v-200d '+%Y%m%d%H%M' 2>/dev/null || date -d '200 days ago' '+%Y%m%d%H%M' 2>/dev/null)
if [[ -n "$old_ts" ]]; then
	touch -t "$old_ts" "$DRIFT_DEPLOYED/pulse-wrapper.sh"
fi

out=$(_run_detector "$RULES_DIR/deployed-vs-source-mtime-drift.sh" \
	"AIDEVOPS_DEPLOYED_DIR=$DRIFT_DEPLOYED" \
	"AIDEVOPS_SOURCE_DIR=$DRIFT_SOURCE" \
	"DRIFT_SECONDS=3600" \
	"WATCHED_FILES=pulse-wrapper.sh") && rc=0 || rc=$?
assert_rc "3.1 firing fixture returns 1" "1" "$rc"
assert_contains "3.2 firing body has correct id" '"id": "deployed-vs-source-mtime-drift"' "$out"
assert_contains "3.3 firing references file" "pulse-wrapper.sh" "$out"
assert_contains "3.4 firing body has marker" 'detector=deployed-vs-source-mtime-drift' "$out"
assert_contains "3.5 firing body embeds bounded comparison evidence" "-deployed-content" "$out"
assert_contains "3.6 firing body embeds source-side comparison evidence" "+source-content" "$out"
assert_contains "3.7 firing body embeds SHA-256 evidence" "Deployed SHA-256" "$out"
assert_not_contains "3.8 worker brief omits canonical source directory" "$DRIFT_SOURCE" "$out"
assert_not_contains "3.9 worker brief omits trusted deployed directory" "$DRIFT_DEPLOYED" "$out"

# Clean fixture: same mtime on both sides
DRIFT_DEPLOYED2="$TMPDIR_TEST/deployed2"
DRIFT_SOURCE2="$TMPDIR_TEST/source2"
mkdir -p "$DRIFT_DEPLOYED2" "$DRIFT_SOURCE2"
echo "x" >"$DRIFT_DEPLOYED2/pulse-wrapper.sh"
echo "x" >"$DRIFT_SOURCE2/pulse-wrapper.sh"
# Touch both with same reference — touch -r preserves mtime exactly.
touch -r "$DRIFT_DEPLOYED2/pulse-wrapper.sh" "$DRIFT_SOURCE2/pulse-wrapper.sh"

out=$(_run_detector "$RULES_DIR/deployed-vs-source-mtime-drift.sh" \
	"AIDEVOPS_DEPLOYED_DIR=$DRIFT_DEPLOYED2" \
	"AIDEVOPS_SOURCE_DIR=$DRIFT_SOURCE2" \
	"DRIFT_SECONDS=3600" \
	"WATCHED_FILES=pulse-wrapper.sh") && rc=0 || rc=$?
assert_rc "3.10 same-mtime fixture returns 0" "0" "$rc"
assert_empty "3.11 same-mtime emits no output" "$out"

# Missing dirs → no-op
out=$(_run_detector "$RULES_DIR/deployed-vs-source-mtime-drift.sh" \
	"AIDEVOPS_DEPLOYED_DIR=/nonexistent/x" \
	"AIDEVOPS_SOURCE_DIR=/nonexistent/y") && rc=0 || rc=$?
assert_rc "3.12 missing dirs returns 0" "0" "$rc"

# ---------------------------------------------------------------------------
# Test 4: log-pattern-novelty
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 4: log-pattern-novelty ---"

LOG_FIRING="$TMPDIR_TEST/log-firing.log"
# Build 1100 lines: first 1000 "old line N", last 100 contain a novel
# template that normalises to a stable string and appears > threshold.
# Threshold = 5; we use 50 occurrences in the recent block.
{
	for i in $(seq 1 1000); do
		printf '2026-04-01T00:00:00Z OLD pattern - existing baseline iteration %d\n' "$i"
	done
	for i in $(seq 1 50); do
		# Each line normalises to:
		# "<TS> NOVEL_ERROR: dispatch_with_dedup payload\tfield unexpected return code <N> from worker_lifecycle iteration <N>"
		printf '2026-04-30T00:00:00Z NOVEL_ERROR: dispatch_with_dedup payload\\tfield unexpected return code 99 from worker_lifecycle iteration %d\n' "$i"
	done
	# Pad recent block to >= RECENT_LINES
	for i in $(seq 1 50); do
		printf '2026-04-30T00:00:00Z OTHER recent line padding iteration %d\n' "$i"
	done
} >"$LOG_FIRING"

out=$(_run_detector "$RULES_DIR/log-pattern-novelty.sh" \
	"LOG_FILE=$LOG_FIRING" \
	"RECENT_LINES=100" \
	"PRIOR_LINES=1000" \
	"NOVELTY_THRESHOLD=10") && rc=0 || rc=$?
assert_rc "4.1 firing fixture returns 1" "1" "$rc"
assert_contains "4.2 firing body has correct id" '"id": "log-pattern-novelty"' "$out"
assert_contains "4.3 firing body cites novel template" "NOVEL_ERROR" "$out"
assert_contains "4.4 firing body preserves literal backslash evidence" 'payload\\tfield' "$out"
assert_contains "4.5 firing body has marker" 'detector=log-pattern-novelty' "$out"

# Regression fixture for GH#29485: PID-specific normalization must run before
# the broad hexadecimal rule so equivalent 6- and 7-digit PIDs share a template.
LOG_PID_STABLE="$TMPDIR_TEST/log-pid-stable.log"
{
	for _ in $(seq 1 100); do
		printf 'Acquired lock (PID 607677, age 5s, holder: pulse-instance-lock.sh)\n'
	done
	for _ in $(seq 1 100); do
		printf 'Acquired lock (PID 1220368, age 5s, holder: pulse-instance-lock.sh)\n'
	done
} >"$LOG_PID_STABLE"

out=$(_run_detector "$RULES_DIR/log-pattern-novelty.sh" \
	"LOG_FILE=$LOG_PID_STABLE" \
	"RECENT_LINES=100" \
	"PRIOR_LINES=100" \
	"NOVELTY_THRESHOLD=10") && rc=0 || rc=$?
assert_rc "4.6 equivalent 6- and 7-digit PID templates return 0" "0" "$rc"
assert_empty "4.7 equivalent PID templates emit no finding" "$out"

# Clean fixture: log too short → no-op
LOG_SHORT="$TMPDIR_TEST/log-short.log"
for i in $(seq 1 50); do
	printf 'short line %d\n' "$i"
done >"$LOG_SHORT"

out=$(_run_detector "$RULES_DIR/log-pattern-novelty.sh" \
	"LOG_FILE=$LOG_SHORT" \
	"RECENT_LINES=100") && rc=0 || rc=$?
assert_rc "4.8 too-short log returns 0" "0" "$rc"

# Missing log → no-op
out=$(_run_detector "$RULES_DIR/log-pattern-novelty.sh" \
	"LOG_FILE=/nonexistent/log.log") && rc=0 || rc=$?
assert_rc "4.9 missing log returns 0" "0" "$rc"

# ---------------------------------------------------------------------------
# Test 5: idle-state-stuck
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 5: idle-state-stuck ---"

PID_FIRING="$TMPDIR_TEST/pid-firing.pid"
echo "SETUP:99999" >"$PID_FIRING"

# Fake "PID dead" callable
FAKE_DEAD="$TMPDIR_TEST/pid-dead.sh"
cat >"$FAKE_DEAD" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$FAKE_DEAD"

out=$(_run_detector "$RULES_DIR/idle-state-stuck.sh" \
	"PID_FILE=$PID_FIRING" \
	"PID_ALIVE_FN=$FAKE_DEAD") && rc=0 || rc=$?
assert_rc "5.1 firing fixture (dead PID) returns 1" "1" "$rc"
assert_contains "5.2 firing body has correct id" '"id": "idle-state-stuck"' "$out"
assert_contains "5.3 firing title cites stuck PID" "SETUP:99999" "$out"
assert_contains "5.4 firing body has marker" 'detector=idle-state-stuck' "$out"

# Clean fixture: PID alive
FAKE_ALIVE="$TMPDIR_TEST/pid-alive.sh"
cat >"$FAKE_ALIVE" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$FAKE_ALIVE"

out=$(_run_detector "$RULES_DIR/idle-state-stuck.sh" \
	"PID_FILE=$PID_FIRING" \
	"PID_ALIVE_FN=$FAKE_ALIVE") && rc=0 || rc=$?
assert_rc "5.5 alive-PID fixture returns 0" "0" "$rc"
assert_empty "5.6 alive-PID emits no output" "$out"

# No SETUP marker → no-op
PID_CLEAN="$TMPDIR_TEST/pid-clean.pid"
echo "12345" >"$PID_CLEAN"
out=$(_run_detector "$RULES_DIR/idle-state-stuck.sh" \
	"PID_FILE=$PID_CLEAN") && rc=0 || rc=$?
assert_rc "5.7 no-SETUP-marker returns 0" "0" "$rc"
assert_empty "5.8 no-SETUP emits no output" "$out"

# Missing PID file → no-op
out=$(_run_detector "$RULES_DIR/idle-state-stuck.sh" \
	"PID_FILE=/nonexistent/pulse.pid") && rc=0 || rc=$?
assert_rc "5.9 missing PID file returns 0" "0" "$rc"

# ---------------------------------------------------------------------------
# Test 6: orchestrator end-to-end (--dry-run, --only)
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 6: orchestrator integration ---"

# Use the firing counter-trend fixture from Section 1.
# --json should emit one finding object on stdout.
out=$(STATS_FILE="$STATS_FIRING" \
	NOW_EPOCH=1000 \
	WINDOW_SECONDS=100 \
	REGRESSION_MULT=2 \
	MIN_BASELINE=1 \
	"$ORCHESTRATOR" --dry-run --only counter-trend-delta --json 2>/dev/null) && rc=0 || rc=$?
assert_rc "6.1 orchestrator --json --only returns 0" "0" "$rc"
assert_contains "6.2 orchestrator --json emits id field" '"id"' "$out"
assert_contains "6.3 orchestrator --json emits counter-trend-delta" 'counter-trend-delta' "$out"

# `list` subcommand should print all 5 detectors
out=$("$ORCHESTRATOR" list 2>/dev/null) && rc=0 || rc=$?
assert_rc "6.4 orchestrator list returns 0" "0" "$rc"
assert_contains "6.5 list shows counter-trend-delta" "counter-trend-delta" "$out"
assert_contains "6.6 list shows process-count-anomaly" "process-count-anomaly" "$out"
assert_contains "6.7 list shows deployed-vs-source-mtime-drift" "deployed-vs-source-mtime-drift" "$out"
assert_contains "6.8 list shows log-pattern-novelty" "log-pattern-novelty" "$out"
assert_contains "6.9 list shows idle-state-stuck" "idle-state-stuck" "$out"

# --only with non-existent detector should run nothing and exit 0
out=$("$ORCHESTRATOR" --dry-run --only nonexistent-detector --json 2>/dev/null) && rc=0 || rc=$?
assert_rc "6.10 --only nonexistent detector returns 0" "0" "$rc"
assert_empty "6.11 --only nonexistent emits no JSON output" "$out"

# ---------------------------------------------------------------------------
# Test 7: shellcheck on all new files
# ---------------------------------------------------------------------------
echo ""
echo "--- Section 7: shellcheck ---"

if command -v shellcheck >/dev/null 2>&1; then
	for f in "$RULES_DIR"/*.sh "$ORCHESTRATOR"; do
		[[ -f "$f" ]] || continue
		if shellcheck -x "$f" >/dev/null 2>&1; then
			TESTS_RUN=$((TESTS_RUN + 1))
			echo "${TEST_GREEN}PASS${TEST_NC}: shellcheck clean on $(basename "$f")"
		else
			TESTS_RUN=$((TESTS_RUN + 1))
			TESTS_FAILED=$((TESTS_FAILED + 1))
			echo "${TEST_RED}FAIL${TEST_NC}: shellcheck violations on $(basename "$f")"
			shellcheck -x "$f" 2>&1 | head -10 | sed 's/^/    /'
		fi
	done
else
	echo "${TEST_BLUE}SKIP${TEST_NC}: shellcheck not installed"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "${TEST_BLUE}=== Summary ===${TEST_NC}"
echo "Tests run:    $TESTS_RUN"
echo "Tests failed: $TESTS_FAILED"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
	echo "${TEST_GREEN}ALL TESTS PASSED${TEST_NC}"
	exit 0
else
	echo "${TEST_RED}$TESTS_FAILED TEST(S) FAILED${TEST_NC}"
	exit 1
fi
