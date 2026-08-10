#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# Regression coverage for GH#29888 incremental scheduling and health state.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)" || exit 1
PULSE_SCRIPT="${REPO_ROOT}/.agents/scripts/session-miner-pulse.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_HOME="${TEST_ROOT}/home"
FAKE_MINER_SOURCE="${TEST_ROOT}/miner-source"
FAKE_DB="${TEST_ROOT}/sessions.db"
EXTRACT_LOG="${TEST_ROOT}/extract.log"
mkdir -p "$FAKE_HOME" "$FAKE_MINER_SOURCE"
python3 - "$FAKE_DB" <<'PY'
import sys
from pathlib import Path

Path(sys.argv[1]).write_bytes(b"0" * 2048)
PY

cat >"${FAKE_MINER_SOURCE}/extract.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

if "--help" in sys.argv:
    if os.environ.get("FAKE_EXTRACT_CAPABILITY_MISSING") != "1":
        print("--since-ms")
    raise SystemExit(0)
args = sys.argv[1:]
with Path(os.environ["EXTRACT_LOG"]).open("a", encoding="utf-8") as handle:
    handle.write(" ".join(args) + "\n")
if os.environ.get("FAKE_EXTRACT_FAIL") == "1":
    raise SystemExit(9)
output = Path(args[args.index("--output") + 1])
since = None
if "--since-ms" in args:
    since = int(args[args.index("--since-ms") + 1])
chunks = output / "chunks_test"
chunks.mkdir(parents=True, exist_ok=True)
metadata = {
    "window_start_ms": since,
    "window_end_ms": int(os.environ.get("FAKE_HIGH_WATER_MS", "2000")),
    "source_high_water_ms": int(os.environ.get("FAKE_HIGH_WATER_MS", "2000")),
}
(chunks / "stats.json").write_text(
    json.dumps({"type": "stats", "data": {"extraction_metadata": metadata}}),
    encoding="utf-8",
)
print(json.dumps({"extraction_metadata": metadata}))
PY

cat >"${FAKE_MINER_SOURCE}/compress.py" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
from pathlib import Path

if os.environ.get("FAKE_COMPRESS_FAIL") == "1":
    raise SystemExit(8)
chunks = Path(sys.argv[1])
stats = json.loads((chunks / "stats.json").read_text(encoding="utf-8"))["data"]
payload = {
    "steerage": {},
    "errors": {"patterns": []},
    "stats": stats,
    "git_correlation": {},
    "instruction_candidates": {
        ".agents/AGENTS.md": [{
            "text": "PRIVATE RAW SESSION SENTINEL",
            "display_text": "generic candidate",
            "confidence": 0.9,
            "fingerprint": "candidate-one",
            "qualification_basis": "recurring",
            "requires_judgment": False,
            "support": 2,
        }]
    },
}
if os.environ.get("FAKE_EMPTY_SIGNALS") == "1":
    payload["instruction_candidates"] = {}
if os.environ.get("FAKE_BAD_METADATA") == "1":
    payload["stats"] = {}
(chunks.parent / "compressed_signals.json").write_text(json.dumps(payload), encoding="utf-8")
PY
chmod +x "${FAKE_MINER_SOURCE}/extract.py" "${FAKE_MINER_SOURCE}/compress.py"

run_pulse() {
	local now_epoch="$1"
	shift
	HOME="$FAKE_HOME" \
		EXTRACT_LOG="$EXTRACT_LOG" \
		SESSION_MINER_NOW_EPOCH="$now_epoch" \
		SESSION_MINER_INTERVAL=1000 \
		SESSION_MINER_MINER_DIR="${FAKE_HOME}/miner" \
		SESSION_MINER_EXTRACTOR_SRC="${FAKE_MINER_SOURCE}/extract.py" \
		SESSION_MINER_COMPRESSOR_SRC="${FAKE_MINER_SOURCE}/compress.py" \
		bash "$PULSE_SCRIPT" --db "$FAKE_DB" "$@"
	return $?
}

run_pulse 1000 >/dev/null
STATE_FILE="${FAKE_HOME}/miner/state.json"
jq -e '
    .schema_version == 1 and
    .status == "healthy" and
    .source_watermark_ms == 2000 and
    .last_success_epoch == 1000 and
    .schedule.interval_seconds == 1000 and
    .counts.instruction_candidates == 1
' "$STATE_FILE" >/dev/null
if grep -q 'PRIVATE RAW SESSION SENTINEL' "$STATE_FILE"; then
	printf 'health state leaked raw session text\n' >&2
	exit 1
fi

first_count=$(wc -l <"$EXTRACT_LOG" | tr -d ' ')
run_pulse 1100 >/dev/null
second_count=$(wc -l <"$EXTRACT_LOG" | tr -d ' ')
[[ "$first_count" == "1" && "$second_count" == "1" ]]
jq -e '.status == "not_due" and .source_watermark_ms == 2000' "$STATE_FILE" >/dev/null

if FAKE_EXTRACT_FAIL=1 run_pulse 2101 >/dev/null 2>&1; then
	printf 'expected extraction failure\n' >&2
	exit 1
fi
jq -e '
    .status == "failed" and
    .error_class == "extraction_failed" and
    .source_watermark_ms == 2000 and
    .last_success_epoch == 1000
' "$STATE_FILE" >/dev/null
grep -q -- '--since-ms 2000' "$EXTRACT_LOG"

status_json=$(run_pulse 2200 --status --json)
printf '%s' "$status_json" | jq -e '
    .schema_version == 1 and
    .schedule.due == true and
    .freshness.last_success_epoch == 1000 and
    .source_watermark_ms == 2000 and
    .error_class == "extraction_failed"
' >/dev/null

mkdir -p "${FAKE_HOME}/miner/.pulse.lock"
before_lock_count=$(wc -l <"$EXTRACT_LOG" | tr -d ' ')
run_pulse 2300 --force >/dev/null
after_lock_count=$(wc -l <"$EXTRACT_LOG" | tr -d ' ')
[[ "$before_lock_count" == "$after_lock_count" ]]
rm -rf "${FAKE_HOME}/miner/.pulse.lock"

counts_before_replay=$(jq -c '.counts' "$STATE_FILE")
FAKE_EMPTY_SIGNALS=1 run_pulse 3000 --force >/dev/null
counts_after_replay=$(jq -c '.counts' "$STATE_FILE")
[[ "$counts_before_replay" == "$counts_after_replay" ]]
jq -e '.status == "healthy" and .source_watermark_ms == 2000 and .last_success_epoch == 3000' "$STATE_FILE" >/dev/null

if FAKE_COMPRESS_FAIL=1 run_pulse 4101 >/dev/null 2>&1; then
	printf 'expected compression failure\n' >&2
	exit 1
fi
jq -e '
    .status == "failed" and
    .error_class == "compression_failed" and
    .source_watermark_ms == 2000 and
    .last_success_epoch == 3000
' "$STATE_FILE" >/dev/null

if FAKE_EXTRACT_CAPABILITY_MISSING=1 run_pulse 4200 --force >/dev/null 2>&1; then
	printf 'expected missing extractor capability failure\n' >&2
	exit 1
fi
jq -e '
    .status == "failed" and
    .error_class == "extractor_capability_missing" and
    .source_watermark_ms == 2000 and
    .last_success_epoch == 3000
' "$STATE_FILE" >/dev/null

if FAKE_BAD_METADATA=1 run_pulse 4300 --force >/dev/null 2>&1; then
	printf 'expected watermark metadata validation failure\n' >&2
	exit 1
fi
jq -e '
    .status == "failed" and
    .error_class == "watermark_validation_failed" and
    .source_watermark_ms == 2000 and
    .last_success_epoch == 3000
' "$STATE_FILE" >/dev/null

ACTUATION_REPOS="${TEST_ROOT}/repos.json"
FAILING_ACTUATION="${TEST_ROOT}/failing-actuation.sh"
cat >"$ACTUATION_REPOS" <<JSON
{"initialized_repos":[{"slug":"marcusquinn/aidevops","path":"${REPO_ROOT}","role":"maintainer","pulse":true}]}
JSON
cat >"$FAILING_ACTUATION" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$FAILING_ACTUATION"
if REPOS_JSON="$ACTUATION_REPOS" SESSION_MINER_ACTUATION_HELPER="$FAILING_ACTUATION" \
	FAKE_HIGH_WATER_MS=3000 run_pulse 4400 --force --create-issues >/dev/null 2>&1; then
	printf 'expected actuation deferral\n' >&2
	exit 1
fi
jq -e '
    .status == "deferred" and
    .error_class == "actuation_deferred" and
    .source_watermark_ms == 2000 and
    .last_success_epoch == 3000
' "$STATE_FILE" >/dev/null

ROUTINE_CAPTURE="${TEST_ROOT}/routine-capture"
(
	unset _PULSE_ROUTINES_LOADED
	# shellcheck source=../pulse-routines.sh
	source "${REPO_ROOT}/.agents/scripts/pulse-routines.sh"
	LOGFILE="${TEST_ROOT}/routine.log"
	PULSE_DIR="$REPO_ROOT"
	_routine_retry_blocked() { return 1; }
	_routine_last_run_epoch() {
		printf '0'
		return 0
	}
	_routine_schedule_is_due() { return 0; }
	_routine_rest_core_allows_next() { return 0; }
	_routine_execute() {
		printf '%s\n' "$*" >"$ROUTINE_CAPTURE"
		return 0
	}
	_evaluate_session_miner_routine
)
grep -q 'r-session-miner Incremental session insight mining scripts/session-miner-pulse.sh --create-issues' "$ROUTINE_CAPTURE"

LEGACY_HOME="${TEST_ROOT}/legacy-home"
mkdir -p "${LEGACY_HOME}/.aidevops/.agent-workspace/work/session-miner"
printf '777\n' >"${LEGACY_HOME}/.aidevops/.agent-workspace/work/session-miner/.last-pulse"
legacy_status=$(
	HOME="$LEGACY_HOME" SESSION_MINER_NOW_EPOCH=2000 SESSION_MINER_INTERVAL=1000 \
		bash "$PULSE_SCRIPT" --status --json
)
printf '%s' "$legacy_status" | jq -e '
    .status == "legacy_migrated" and
    .freshness.last_success_epoch == 777 and
    .source_watermark_ms == null
' >/dev/null

printf 'session-miner pulse state tests passed\n'
