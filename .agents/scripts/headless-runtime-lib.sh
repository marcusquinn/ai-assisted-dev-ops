#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# =============================================================================
# aidevops Headless Runtime Library -- Stable Utility Functions (t2013)
# =============================================================================
# Shared functions extracted from headless-runtime-helper.sh that provide
# stable utility capabilities: state DB, provider auth, backoff, output
# parsing, metrics, sandbox passthrough, worker contract, watchdog, database
# lifecycle, dispatch ledger, failure reporting, canary, model choice, and cmd
# builders.
#
# Large function groups are split into sub-libraries (GH#19699):
#   - headless-runtime-provider.sh  (auth + backoff)
#   - headless-runtime-database.sh  (database lifecycle)
#   - headless-runtime-failure.sh   (dispatch claim + fast-fail)
#   - headless-runtime-model.sh     (model choice + cmd builders)
#
# Usage: source "${SCRIPT_DIR}/headless-runtime-lib.sh"
#
# Dependencies:
#   - shared-constants.sh (print_error, print_info, print_warning, timeout_sec)
#   - worker-lifecycle-common.sh (escalate_issue_tier, resolve_model_tier)
#   - Constants from headless-runtime-helper.sh (STATE_DIR, STATE_DB, etc.)
#   - bash 3.2+, sqlite3, python3, jq
#
# Mirrors the issue-sync-helper.sh + issue-sync-lib.sh split precedent.
# Part of aidevops framework: https://aidevops.sh

# Apply strict mode only when executed directly (not when sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && set -euo pipefail

# Include guard
[[ -n "${_HEADLESS_RUNTIME_LIB_LOADED:-}" ]] && return 0
readonly _HEADLESS_RUNTIME_LIB_LOADED=1

# Resolve SCRIPT_DIR if not set by caller, so sub-library sourcing works when
# the lib is sourced directly (e.g. from a test harness). Matches the
# issue-sync-lib.sh precedent; a no-op when the caller has already set it.
if [[ -z "${SCRIPT_DIR:-}" ]]; then
	_lib_path="${BASH_SOURCE[0]%/*}"
	[[ "$_lib_path" == "${BASH_SOURCE[0]}" ]] && _lib_path="."
	SCRIPT_DIR="$(cd "$_lib_path" && pwd)"
	unset _lib_path
fi

# --- Section 1: State DB ---

init_state_db() {
	mkdir -p "$STATE_DIR" 2>/dev/null || true
	sqlite3 "$STATE_DB" <<'SQL' >/dev/null 2>&1
PRAGMA journal_mode=WAL;
PRAGMA busy_timeout=5000;

CREATE TABLE IF NOT EXISTS provider_backoff (
    provider       TEXT PRIMARY KEY,
    reason         TEXT NOT NULL,
    retry_after    TEXT DEFAULT '',
    auth_signature TEXT DEFAULT '',
    details        TEXT DEFAULT '',
    updated_at     TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS provider_sessions (
    provider     TEXT NOT NULL,
    session_key  TEXT NOT NULL,
    session_id   TEXT NOT NULL,
    model        TEXT NOT NULL,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (provider, session_key)
);

CREATE TABLE IF NOT EXISTS provider_rotation (
    role         TEXT PRIMARY KEY,
    last_provider TEXT NOT NULL,
    updated_at   TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);

CREATE TABLE IF NOT EXISTS provider_startup_failures (
    provider   TEXT NOT NULL,
    model      TEXT NOT NULL,
    count      INTEGER NOT NULL DEFAULT 0,
    first_seen TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    updated_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now')),
    PRIMARY KEY (provider, model)
);

CREATE TABLE IF NOT EXISTS private_workload_locks (
    lock_key        TEXT PRIMARY KEY,
    owner_pid       INTEGER NOT NULL,
    owner_argv_hash TEXT NOT NULL DEFAULT '',
    updated_at      TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%SZ', 'now'))
);
SQL
	return 0
}

db_query() {
	local query="$1"
	sqlite3_with_timeout "$STATE_DB" "$query" 2>/dev/null
	return $?
}

sqlite3_with_timeout() {
	sqlite3 -cmd ".timeout 5000" "$@"
	return $?
}

sql_escape() {
	local value="$1"
	printf '%s' "${value//\'/\'\'}"
	return 0
}

trim_spaces() {
	local value="$1"
	value="${value#"${value%%[![:space:]]*}"}"
	value="${value%"${value##*[![:space:]]}"}"
	printf '%s' "$value"
	return 0
}

# --- Sub-library sourcing (GH#19699) ---
# Provider auth + backoff (Sections 2-3)
# shellcheck source=./headless-runtime-provider.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-provider.sh"

# --- Section 4: Output Parsing ---

_classify_trusted_provider_failure() {
	local file_path="$1"
	local classifier="${SCRIPT_DIR}/headless-runtime-provider-classifier.py"
	if [[ -f "$classifier" ]] && python3 "$classifier" "$file_path"; then
		return 0
	fi
	return 1
}

_read_failure_output_lowercase() {
	local file_path="$1"
	if python3 - "$file_path" <<'PY'; then
from pathlib import Path
import sys
print(Path(sys.argv[1]).read_text(errors="ignore").lower())
PY
		return 0
	fi
	return 1
}

_emit_local_runtime_failure() {
	local runtime_type="$1"
	local classification_source="$2"
	local classification_pattern="$3"
	_failure_runtime_error_type="$runtime_type"
	_failure_classification_source="$classification_source"
	_failure_classification_pattern="$classification_pattern"
	printf '%s' "local_error"
	return 0
}

_classify_local_runtime_failure() {
	local lowered="$1"
	if [[ "$lowered" == *"sqliteerror: disk i/o error"* ]] || [[ "$lowered" == *"sqlite_error"* && "$lowered" == *"disk i/o"* ]]; then
		_emit_local_runtime_failure "opencode_sqlite_io" "opencode_runtime" "sqlite_disk_io"
		return 0
	fi
	if [[ "$lowered" == *"failed to list snapshot files"* ]] || { [[ "$lowered" == *"fatal: not a git repository"* ]] && [[ "$lowered" == *"snapshot"* ]]; }; then
		_emit_local_runtime_failure "opencode_snapshot_git" "opencode_runtime" "snapshot_git_failure"
		return 0
	fi
	if [[ "$lowered" == *"spawn"* && "$lowered" == *"enoent"* ]] || [[ "$lowered" == *"command not found"* ]] || [[ "$lowered" == *"no such file or directory"* && "$lowered" == *"opencode"* ]]; then
		_emit_local_runtime_failure "runtime_command_missing" "local_runtime" "command_missing|spawn_enoent"
		return 0
	fi
	if [[ "$lowered" == *"permission denied"* ]] || [[ "$lowered" == *"eacces"* ]]; then
		_emit_local_runtime_failure "runtime_permission_denied" "local_runtime" "permission_denied|eacces"
		return 0
	fi
	if [[ "$lowered" == *"no space left on device"* ]] || [[ "$lowered" == *"enospc"* ]]; then
		_emit_local_runtime_failure "runtime_storage_full" "local_runtime" "no_space_left|enospc"
		return 0
	fi
	return 1
}

classify_failure_reason() {
	local file_path="$1"
	_failure_provider_error_type=""
	_failure_provider_status=""
	_failure_runtime_error_type=""
	_failure_classification_source="output_pattern"
	_failure_classification_pattern=""
	local classification=""
	local classified_reason="" classified_provider_type="" classified_status="" classified_source="" classified_pattern=""
	classification=$(_classify_trusted_provider_failure "$file_path")
	if [[ -n "$classification" ]]; then
		IFS=$'\t' read -r classified_reason classified_provider_type classified_status classified_source classified_pattern <<<"$classification"
		_failure_provider_error_type="$classified_provider_type"
		_failure_provider_status="$classified_status"
		_failure_classification_source="$classified_source"
		_failure_classification_pattern="$classified_pattern"
		printf '%s' "$classified_reason"
		return 0
	fi
	local lowered
	lowered=$(_read_failure_output_lowercase "$file_path")
	if _classify_local_runtime_failure "$lowered"; then
		return 0
	fi
	# Provider/rate-limit/auth/server classification intentionally uses only
	# trusted chunks above. Generic tool output, file reads, docs, and skill
	# content can mention provider failures and must not trigger backoff.
	# Default: local_error -- do NOT record provider backoff for this
	_failure_classification_source="default_local"
	_failure_classification_pattern="default_local"
	printf '%s' "local_error"
	return 0
}

service_interruption_continue_candidate() {
	local failure_reason="$1"
	local exit_code="$2"
	local activity_detected="$3"
	local session_id="$4"
	: "${5:-}"

	if [[ "$failure_reason" == "provider_error" || "$failure_reason" == "auth_error" ]]; then
		if [[ "$activity_detected" == "1" || -n "$session_id" ]]; then
			return 0
		fi
	fi

	if [[ "$activity_detected" == "1" ]]; then
		case "$exit_code" in
		137)
			return 0
			;;
		esac
	fi

	return 1
}

runtime_signal_terminated_candidate() {
	local output_file="$1"
	local exit_code="$2"
	local activity_detected="$3"

	if [[ "$activity_detected" != "1" ]]; then
		return 1
	fi
	if [[ "${exit_code:-}" == "143" ]]; then
		return 0
	fi
	if [[ ! -f "$output_file" ]]; then
		return 1
	fi
	python3 - "$output_file" <<'PY'
import sys
from pathlib import Path

try:
    lines = [line.strip() for line in Path(sys.argv[1]).read_text(errors="ignore").splitlines() if line.strip()]
except OSError:
    sys.exit(1)
if not lines:
    sys.exit(1)
tail = "\n".join(lines[-5:]).lower()
if lines[-1].lower() == "terminated" or "sigterm" in tail or "received sigterm" in tail:
    sys.exit(0)
sys.exit(1)
PY
	return $?
}

extract_session_id_from_output() {
	local file_path="$1"
	python3 - "$file_path" <<'PY'
import json
import sys
from pathlib import Path

session_id = ""
for line in Path(sys.argv[1]).read_text(errors="ignore").splitlines():
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    if obj.get("sessionID"):
        session_id = obj["sessionID"]
        continue
    part = obj.get("part") or {}
    if part.get("sessionID"):
        session_id = part["sessionID"]
print(session_id)
PY
	return 0
}

output_has_activity() {
	local file_path="$1"
	python3 - "$file_path" <<'PY'
import json
import sys
from pathlib import Path

activity = False
for line in Path(sys.argv[1]).read_text(errors="ignore").splitlines():
    line = line.strip()
    if not line or not line.startswith("{"):
        continue
    try:
        obj = json.loads(line)
    except Exception:
        continue
    event_type = obj.get("type", "")
    if event_type in {"text", "tool", "tool-invocation", "tool-result", "step_start", "step_finish", "reasoning"}:
        activity = True
        break

print("1" if activity else "0")
PY
	return 0
}

#######################################
# _log_empty_result_gaps: scan worker output for empty tool results that
# preceded the model stopping. Each is a gap (wrong path, missing prefix)
# that can be closed with better hints or fallback patterns.
# Logs to ~/.aidevops/logs/worker-empty-results.log for pattern analysis.
# Args: $1=output_file $2=model $3=session_key
#######################################
_log_empty_result_gaps() {
	local output_file="$1"
	local model="$2"
	local session_key="$3"

	[[ -f "$output_file" ]] || return 0

	local diag_log="${HOME}/.aidevops/logs/worker-empty-results.log"
	mkdir -p "$(dirname "$diag_log")" 2>/dev/null || true

	local _py_script
	# t2997: drop .py — XXXXXX must be at end for BSD mktemp; python doesn't
	# need .py to execute via `python "$path"`.
	_py_script=$(mktemp "${TMPDIR:-/tmp}/aidevops-empty-gaps-XXXXXX") || return 0
	cat >"$_py_script" <<'EMPTYPY'
import json, sys, os, datetime
from pathlib import Path
of = os.environ.get("ER_OUTPUT_FILE", "")
md = os.environ.get("ER_MODEL", "")
sk = os.environ.get("ER_SESSION_KEY", "")
dl = os.environ.get("ER_DIAG_LOG", "")
if not of or not dl:
    sys.exit(0)
lines = Path(of).read_text(errors="ignore").splitlines()
gaps, tc = [], 0
for ln in lines:
    ln = ln.strip()
    if not ln.startswith("{"):
        continue
    try:
        o = json.loads(ln)
    except Exception:
        continue
    if o.get("type") == "tool_use":
        tc += 1
        st = o.get("part", {}).get("state", {})
        ip = st.get("input", {})
        out = (st.get("output", "") or "").strip()
        empty = (out == "" or out == "0" or out == "\n"
                 or ("grep" == o["part"].get("tool", "") and "Found 0 matches" in out))
        if empty:
            det = ((ip.get("command", "") or "")[:120]
                   or (ip.get("pattern", "") or "")[:80]
                   or (ip.get("filePath", "") or "")[:120]
                   or (ip.get("description", "") or "")[:80])
            gaps.append({"t": o["part"].get("tool", ""), "d": det, "i": tc})
if not gaps:
    sys.exit(0)
ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
with open(dl, "a") as f:
    f.write("\n[%s] model=%s session=%s tools=%d empty=%d\n" % (ts, md, sk, tc, len(gaps)))
    for g in gaps:
        f.write("  #%d/%d %s -> EMPTY: %s\n" % (g["i"], tc, g["t"], g["d"]))
print("[empty-result-gaps] %d empty in %d tool calls:" % (len(gaps), tc))
for g in gaps:
    print("  [%d/%d] %s -> EMPTY: %s" % (g["i"], tc, g["t"], g["d"][:100]))
EMPTYPY
	ER_OUTPUT_FILE="$output_file" ER_MODEL="$model" ER_SESSION_KEY="$session_key" ER_DIAG_LOG="$diag_log" \
		python3 "$_py_script" 2>/dev/null || true
	rm -f "$_py_script" 2>/dev/null || true
	return 0
}

# --- Section 5: Metrics ---

append_runtime_metric() {
	local role="$1"
	local session_key="$2"
	local model="$3"
	local provider="$4"
	local result="$5"
	local exit_code="$6"
	local failure_reason="$7"
	local activity="$8"
	local duration_ms="$9"
	local issue_number="${10:-}"
	local repo_slug="${11:-}"
	local work_dir="${12:-}"
	local output_file="${13:-}"
	local session_id="${14:-}"
	local provider_error_type="${15:-}"
	local provider_status="${16:-}"
	local runtime_error_type="${17:-}"
	local classification_source="${18:-}"
	local classification_pattern="${19:-}"
	local launch_failure_cause="${20:-}"
	local kill_reason="${21:-}"
	local next_action="${22:-}"
	mkdir -p "$METRICS_DIR" 2>/dev/null || true
	ROLE="$role" SESSION_KEY="$session_key" MODEL="$model" PROVIDER="$provider" \
		RESULT="$result" EXIT_CODE="$exit_code" FAILURE_REASON="$failure_reason" \
		ACTIVITY="$activity" DURATION_MS="$duration_ms" ISSUE_NUMBER="$issue_number" \
		REPO_SLUG="$repo_slug" WORK_DIR="$work_dir" OUTPUT_FILE="$output_file" \
		SESSION_ID="$session_id" PROVIDER_ERROR_TYPE="$provider_error_type" \
		PROVIDER_STATUS="$provider_status" RUNTIME_ERROR_TYPE="$runtime_error_type" \
		CLASSIFICATION_SOURCE="$classification_source" CLASSIFICATION_PATTERN="$classification_pattern" \
		LAUNCH_FAILURE_CAUSE="$launch_failure_cause" KILL_REASON="$kill_reason" NEXT_ACTION="$next_action" \
		WORKER_ID="${AIDEVOPS_WORKER_ID:-}" PARENT_WORKER_ID="${AIDEVOPS_PARENT_WORKER_ID:-}" \
		ROOT_WORKER_ID="${AIDEVOPS_ROOT_WORKER_ID:-}" CORRELATION_ID="${AIDEVOPS_CORRELATION_ID:-}" \
		ATTEMPT_ID="${AIDEVOPS_ATTEMPT_ID:-}" RUN_ID="${AIDEVOPS_RUN_ID:-}" \
		ROUTING_TIER="${AIDEVOPS_DISPATCH_TIER:-}" ROUTING_CANDIDATE_INDEX="${AIDEVOPS_ROUTING_CANDIDATE_INDEX:-}" \
		ROUTING_ATTEMPT="${AIDEVOPS_ROUTING_ATTEMPT:-}" ROUTING_REASON="${AIDEVOPS_ROUTING_REASON:-}" \
		ROUTING_ESCALATED="${AIDEVOPS_ROUTING_ESCALATED:-}" ROUTING_VARIANT="${AIDEVOPS_ROUTING_VARIANT:-}" \
		OBSERVED_MODEL="${_MODEL_REPLAY_OBSERVED_MODEL:-}" OBSERVED_VARIANT="${_MODEL_REPLAY_OBSERVED_VARIANT:-}" \
		OBSERVED_REQUEST_COUNT="${_MODEL_REPLAY_REQUEST_COUNT:-}" OBSERVED_USAGE_COUNT="${_MODEL_REPLAY_USAGE_COUNT:-}" \
		OBSERVED_TOKENS_TOTAL="${_MODEL_REPLAY_TOKENS_TOTAL:-}" OBSERVED_COST_COUNT="${_MODEL_REPLAY_COST_COUNT:-}" \
		OBSERVED_COST_USD="${_MODEL_REPLAY_COST_USD:-}" \
		METRICS_PATH="$METRICS_FILE" python3 - <<'PY' >/dev/null 2>&1 || true
import json
import os
import time

record = {
    "ts": int(time.time()),
    "role": os.environ.get("ROLE", ""),
    "session_key": os.environ.get("SESSION_KEY", ""),
    "model": os.environ.get("MODEL", ""),
    "provider": os.environ.get("PROVIDER", ""),
    "result": os.environ.get("RESULT", "unknown"),
    "exit_code": int(os.environ.get("EXIT_CODE", "1") or 1),
    "failure_reason": os.environ.get("FAILURE_REASON", ""),
    "activity": os.environ.get("ACTIVITY", "0") == "1",
    "duration_ms": int(os.environ.get("DURATION_MS", "0") or 0),
}
optional_fields = {
    "issue_number": os.environ.get("ISSUE_NUMBER", ""),
    "repo_slug": os.environ.get("REPO_SLUG", ""),
    "work_dir": os.environ.get("WORK_DIR", ""),
    "output_file": os.environ.get("OUTPUT_FILE", ""),
    "session_id": os.environ.get("SESSION_ID", ""),
    "provider_error_type": os.environ.get("PROVIDER_ERROR_TYPE", ""),
    "provider_status": os.environ.get("PROVIDER_STATUS", ""),
    "runtime_error_type": os.environ.get("RUNTIME_ERROR_TYPE", ""),
    "classification_source": os.environ.get("CLASSIFICATION_SOURCE", ""),
    "classification_pattern": os.environ.get("CLASSIFICATION_PATTERN", ""),
    "launch_failure_cause": os.environ.get("LAUNCH_FAILURE_CAUSE", ""),
    "kill_reason": os.environ.get("KILL_REASON", ""),
    "next_action": os.environ.get("NEXT_ACTION", ""),
    "worker_id": os.environ.get("WORKER_ID", ""),
    "parent_worker_id": os.environ.get("PARENT_WORKER_ID", ""),
    "root_worker_id": os.environ.get("ROOT_WORKER_ID", ""),
    "correlation_id": os.environ.get("CORRELATION_ID", ""),
    "attempt_id": os.environ.get("ATTEMPT_ID", ""),
    "run_id": os.environ.get("RUN_ID", ""),
    "routing_tier": os.environ.get("ROUTING_TIER", ""),
    "routing_candidate_index": os.environ.get("ROUTING_CANDIDATE_INDEX", ""),
    "routing_attempt": os.environ.get("ROUTING_ATTEMPT", ""),
    "routing_reason": os.environ.get("ROUTING_REASON", ""),
    "routing_escalated": os.environ.get("ROUTING_ESCALATED", ""),
    "variant": os.environ.get("ROUTING_VARIANT", ""),
    "observed_model": os.environ.get("OBSERVED_MODEL", ""),
    "observed_variant": os.environ.get("OBSERVED_VARIANT", ""),
    "observed_request_count": os.environ.get("OBSERVED_REQUEST_COUNT", ""),
    "observed_usage_count": os.environ.get("OBSERVED_USAGE_COUNT", ""),
    "observed_tokens_total": os.environ.get("OBSERVED_TOKENS_TOTAL", ""),
    "observed_cost_count": os.environ.get("OBSERVED_COST_COUNT", ""),
    "observed_cost_usd": os.environ.get("OBSERVED_COST_USD", ""),
}
for key, value in optional_fields.items():
    if value != "":
        if key in {"issue_number", "routing_candidate_index", "routing_attempt", "observed_request_count", "observed_usage_count", "observed_tokens_total", "observed_cost_count"}:
            try:
                record[key] = int(value)
            except ValueError:
                record[key] = value
        elif key == "observed_cost_usd":
            try:
                record[key] = float(value)
            except ValueError:
                record[key] = value
        elif key == "routing_escalated":
            record[key] = value == "1"
        else:
            record[key] = value
try:
    load_1min, _load_5min, _load_15min = os.getloadavg()
    cpu_count = os.cpu_count() or 0
    record["load_1min"] = round(load_1min, 2)
    record["cpu_count"] = cpu_count
    record["load_per_cpu"] = round(load_1min / cpu_count, 3) if cpu_count else None
except (AttributeError, OSError):
    record["load_1min"] = None
    record["cpu_count"] = os.cpu_count() or 0
    record["load_per_cpu"] = None
with open(os.environ["METRICS_PATH"], "a") as f:
    f.write(json.dumps(record, separators=(",", ":")) + "\n")
PY
	return 0
}

_execute_metrics_analysis() {
	local role_filter="$1"
	local hours="$2"
	local model_filter="$3"
	local fast_threshold_secs="$4"

	ROLE_FILTER="$role_filter" HOURS="$hours" MODEL_FILTER="$model_filter" FAST_THRESHOLD_SECS="$fast_threshold_secs" METRICS_PATH="$METRICS_FILE" python3 - <<'PY'
import json
import os
import time
from collections import defaultdict

metrics_path = os.environ["METRICS_PATH"]
role_filter = os.environ.get("ROLE_FILTER", "pulse")
hours = int(os.environ.get("HOURS", "24"))
model_filter = os.environ.get("MODEL_FILTER", "")
fast_threshold_secs = int(os.environ.get("FAST_THRESHOLD_SECS", "120"))
cutoff = int(time.time()) - (hours * 3600)

def is_expensive_model(model: str) -> bool:
    normalized = (model or "").lower()
    return any(token in normalized for token in (
        "gpt-5.4",
        "claude-opus",
        "gemini-2.5-pro",
        "cursor/composer-2",
    )) or normalized in {"opus", "pro"}

rows = []
with open(metrics_path) as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
        except Exception:
            continue
        if int(row.get("ts", 0)) < cutoff:
            continue
        if role_filter and row.get("role") != role_filter:
            continue
        model = row.get("model", "")
        if model_filter and model_filter not in model:
            continue
        rows.append(row)

if not rows:
    print("No matching runtime metrics in selected window")
    raise SystemExit(0)

agg = defaultdict(lambda: {"runs": 0, "success": 0, "productive": 0, "retry_recovered": 0, "sum_duration": 0, "fast_productive": 0})
for row in rows:
    model = row.get("model", "unknown")
    item = agg[model]
    item["runs"] += 1
    if row.get("result") == "success":
        item["success"] += 1
    if row.get("result") == "success" and bool(row.get("activity", False)):
        item["productive"] += 1
        if int(row.get("duration_ms", 0) or 0) <= (fast_threshold_secs * 1000):
            item["fast_productive"] += 1
    if int(row.get("exit_code", 1)) == 76:
        item["retry_recovered"] += 1
    item["sum_duration"] += int(row.get("duration_ms", 0) or 0)

print(f"Headless runtime metrics (window={hours}h, role={role_filter}, fast_threshold={fast_threshold_secs}s)")
review_candidates = []
for model in sorted(agg.keys()):
    item = agg[model]
    runs = item["runs"]
    success_pct = (item["success"] / runs) * 100 if runs else 0
    productive_pct = (item["productive"] / runs) * 100 if runs else 0
    avg_sec = (item["sum_duration"] / runs) / 1000 if runs else 0
    print(f"- {model}: runs={runs}, success={item['success']} ({success_pct:.1f}%), productive={item['productive']} ({productive_pct:.1f}%), fast_productive={item['fast_productive']} (<={fast_threshold_secs}s), pool-recovered={item['retry_recovered']}, avg_duration={avg_sec:.1f}s")
    if item["fast_productive"] > 0 and is_expensive_model(model):
        review_candidates.append((model, item["fast_productive"], item["productive"]))

if review_candidates:
    print("Review candidates:")
    for model, fast_count, productive_count in review_candidates:
        print(f"- {model}: {fast_count}/{productive_count} productive successful runs finished within {fast_threshold_secs}s; review tier labels for simplification/doc work and prefer a cheaper default where possible")
PY
	return 0
}

# --- Section 6: Sandbox Passthrough ---

_headless_provider_env_allowed() {
	local provider="$1"
	local name="$2"

	case "$name" in
	OPENAI_*) [[ "$provider" == "openai" ]] && return 0 ;;
	ANTHROPIC_* | CLAUDE_*) [[ "$provider" == "anthropic" ]] && return 0 ;;
	GOOGLE_*) [[ "$provider" == "google" ]] && return 0 ;;
	esac

	return 1
}

# Public triage receives only the selected provider's minimal authentication
# variables. Provider-prefixed endpoint, proxy, organization, and administrative
# controls must not cross this untrusted-content boundary.
_headless_triage_provider_env_allowed() {
	local provider="$1"
	local name="$2"

	case "${provider}:${name}" in
	openai:OPENAI_API_KEY) return 0 ;;
	anthropic:ANTHROPIC_API_KEY | anthropic:CLAUDE_CODE_OAUTH_TOKEN) return 0 ;;
	google:GOOGLE_API_KEY | google:GEMINI_API_KEY | google:GOOGLE_OAUTH_ACCESS_TOKEN) return 0 ;;
	esac

	return 1
}

copy_scoped_opencode_auth() {
	local source_auth="$1"
	local dest_auth="$2"
	local provider="${3:-}"
	local strict_scope="${4:-false}"
	local dest_dir

	[[ -f "$source_auth" ]] || return 0
	dest_dir=$(dirname "$dest_auth")
	mkdir -p "$dest_dir"

	if [[ -n "$provider" ]] && command -v jq >/dev/null 2>&1; then
		local tmp_auth="${dest_auth}.tmp.$$"
		if jq --arg p "$provider" 'if has($p) then {($p): .[$p]} else {} end' \
			"$source_auth" >"$tmp_auth" 2>/dev/null; then
			mv "$tmp_auth" "$dest_auth"
			chmod 600 "$dest_auth" 2>/dev/null || true
			return 0
		fi
		rm -f "$tmp_auth" 2>/dev/null || true
	fi
	if [[ "$strict_scope" == "true" ]]; then
		return 1
	fi

	cp "$source_auth" "$dest_auth" 2>/dev/null || true
	chmod 600 "$dest_auth" 2>/dev/null || true
	return 0
}

run_without_opencode_session_env() {
	env -u AIDEVOPS_OPENCODE_SESSION_ID \
		-u OPENCODE_SESSION_ID \
		-u OPENCODE_PID \
		-u OPENCODE_RUN_ID \
		-u OPENCODE_PROCESS_ROLE \
		-u OPENCODE \
		-u OPENCODE_SERVER_PASSWORD \
		"$@"
	return $?
}

# Replace the inherited process-scoped Git config with the three signing
# entries added by _configure_headless_worker_signing_env. The clean sandbox
# can then inherit a contiguous GIT_CONFIG_* set without admitting unrelated
# ambient Git configuration that happened to precede those entries.
_headless_git_config_env_value() {
	local variable_name="$1"
	printf '%s' "${!variable_name:-}"
	return 0
}

prepare_headless_signing_sandbox_env() {
	local role="${1:-worker}"
	local format_key="gpg.format" signing_key_name="user.signingkey"
	local required_key="commit.gpgsign" format_value="ssh" required_value="true"
	[[ "$role" == "worker" ]] || return 0
	[[ "${_AIDEVOPS_HEADLESS_SIGNING_ENV_CONFIGURED:-0}" == "1" ]] || return 0
	local config_start="${_AIDEVOPS_HEADLESS_SIGNING_GIT_CONFIG_START:-}"
	# A proven pre-existing signing setup does not add dynamic entries and needs
	# no sandbox passthrough. Preserve that migration path (GH#29902).
	[[ -n "$config_start" ]] || return 0
	local config_count="${GIT_CONFIG_COUNT:-}"
	[[ "$config_start" =~ ^[0-9]+$ && "$config_count" =~ ^[0-9]+$ ]] || return 1
	[[ "$config_count" -eq $((config_start + 3)) ]] || return 1

	local source_key_var="" source_value_var="" source_key="" source_value=""
	local signing_format="" signing_key="" signing_required=""
	printf -v source_key_var 'GIT_CONFIG_KEY_%s' "$config_start"
	printf -v source_value_var 'GIT_CONFIG_VALUE_%s' "$config_start"
	source_key=$(_headless_git_config_env_value "$source_key_var")
	source_value=$(_headless_git_config_env_value "$source_value_var")
	[[ "$source_key" == "$format_key" && "$source_value" == "$format_value" ]] || return 1
	signing_format="$source_value"
	config_start=$((config_start + 1))
	printf -v source_key_var 'GIT_CONFIG_KEY_%s' "$config_start"
	printf -v source_value_var 'GIT_CONFIG_VALUE_%s' "$config_start"
	source_key=$(_headless_git_config_env_value "$source_key_var")
	source_value=$(_headless_git_config_env_value "$source_value_var")
	[[ "$source_key" == "$signing_key_name" && -n "$source_value" ]] || return 1
	signing_key="$source_value"
	config_start=$((config_start + 1))
	printf -v source_key_var 'GIT_CONFIG_KEY_%s' "$config_start"
	printf -v source_value_var 'GIT_CONFIG_VALUE_%s' "$config_start"
	source_key=$(_headless_git_config_env_value "$source_key_var")
	source_value=$(_headless_git_config_env_value "$source_value_var")
	[[ "$source_key" == "$required_key" && "$source_value" == "$required_value" ]] || return 1
	signing_required="$source_value"

	export GIT_CONFIG_COUNT=3
	export GIT_CONFIG_KEY_0="$format_key" GIT_CONFIG_VALUE_0="$signing_format"
	export GIT_CONFIG_KEY_1="$signing_key_name" GIT_CONFIG_VALUE_1="$signing_key"
	export GIT_CONFIG_KEY_2="$required_key" GIT_CONFIG_VALUE_2="$signing_required"
	export _AIDEVOPS_HEADLESS_SIGNING_GIT_CONFIG_START=0
	return 0
}

_headless_signing_sandbox_env_is_normalized() {
	[[ "${_AIDEVOPS_HEADLESS_SIGNING_ENV_CONFIGURED:-0}" == "1" ]] || return 1
	[[ "${_AIDEVOPS_HEADLESS_SIGNING_GIT_CONFIG_START:-}" == "0" ]] || return 1
	[[ "${GIT_CONFIG_COUNT:-}" == "3" ]] || return 1
	local normalized_signature=""
	normalized_signature="${GIT_CONFIG_KEY_0:-}=${GIT_CONFIG_VALUE_0:-}|${GIT_CONFIG_KEY_1:-}|${GIT_CONFIG_KEY_2:-}=${GIT_CONFIG_VALUE_2:-}"
	[[ "$normalized_signature" == "gpg.format=ssh|user.signingkey|commit.gpgsign=true" ]] || return 1
	[[ -n "${GIT_CONFIG_VALUE_1:-}" ]] || return 1
	return 0
}

_normalize_headless_github_origin() {
	local origin="$1"
	origin="${origin%.git}"
	[[ "$origin" =~ ^https://github\.com/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$ ]] || return 1
	printf 'https://github.com/%s/%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
	return 0
}

_headless_git_auth_reject() {
	# Reasons are fixed literals from local gates, never credential/metadata values.
	local reason="$1"
	_HEADLESS_GIT_AUTH_REJECTION="$reason"
	printf 'worker_git_auth_rejected reason=%s\n' "$_HEADLESS_GIT_AUTH_REJECTION" >&2
	return 1
}

prepare_headless_git_auth_sandbox_env() {
	local role="${1:-worker}"
	local token_file="${AIDEVOPS_GIT_AUTH_TOKEN_FILE:-}"
	unset _AIDEVOPS_HEADLESS_GIT_AUTH_ENV_CONFIGURED
	_HEADLESS_GIT_AUTH_REJECTION=""
	[[ "$role" == "worker" ]] || return 0
	[[ -n "$token_file" ]] || return 0
	local expected_origin="${AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN:-}"
	local repo_slug="${WORKER_REPO_SLUG:-}"
	local askpass="${GIT_ASKPASS:-}"
	local expected_askpass="${SCRIPT_DIR}/github-auth-askpass.sh"
	local token_helper="${SCRIPT_DIR}/worker-token-helper.sh"
	local normalized_origin=""
	[[ "$repo_slug" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || {
		_headless_git_auth_reject repository_invalid
		return 1
	}
	normalized_origin=$(_normalize_headless_github_origin "$expected_origin") || {
		_headless_git_auth_reject origin_invalid
		return 1
	}
	[[ "$normalized_origin" == "https://github.com/${repo_slug}" ]] || {
		_headless_git_auth_reject repository_mismatch
		return 1
	}
	# aidevops:trust-boundary — accept path aliases only for the very same trusted
	# helper, then pin the sandbox value to the runtime's own path. Never execute
	# the incoming path to establish its identity.
	[[ -x "$askpass" && -x "$expected_askpass" && "$askpass" -ef "$expected_askpass" ]] || {
		_headless_git_auth_reject askpass_mismatch
		return 1
	}
	[[ -x "$token_helper" ]] || {
		_headless_git_auth_reject validator_unavailable
		return 1
	}
	[[ "${GIT_TERMINAL_PROMPT:-}" == "0" ]] || {
		_headless_git_auth_reject terminal_prompt_enabled
		return 1
	}
	[[ -n "${GIT_AUTHOR_NAME:-}" && -n "${GIT_AUTHOR_EMAIL:-}" &&
		"${GIT_COMMITTER_NAME:-}" == "$GIT_AUTHOR_NAME" &&
		"${GIT_COMMITTER_EMAIL:-}" == "$GIT_AUTHOR_EMAIL" &&
		"$GIT_AUTHOR_NAME" != *$'\n'* && "$GIT_AUTHOR_EMAIL" != *$'\n'* &&
		"$GIT_AUTHOR_NAME" != *$'\r'* && "$GIT_AUTHOR_EMAIL" != *$'\r'* ]] || {
		_headless_git_auth_reject identity_invalid
		return 1
	}
	# aidevops:trust-boundary — only a locally validated, repository-bound token
	# contract may cross the clean worker sandbox.
	"$token_helper" validate --token-file "$token_file" --repo "$repo_slug" --local-only \
		>/dev/null 2>&1 || {
		_headless_git_auth_reject token_invalid
		return 1
	}
	export GIT_ASKPASS="$expected_askpass"
	export _AIDEVOPS_HEADLESS_GIT_AUTH_ENV_CONFIGURED=1
	return 0
}

_headless_git_auth_sandbox_env_is_normalized() {
	[[ "${_AIDEVOPS_HEADLESS_GIT_AUTH_ENV_CONFIGURED:-0}" == "1" ]] || return 1
	[[ -n "${AIDEVOPS_GIT_AUTH_TOKEN_FILE:-}" ]] || return 1
	[[ "${GIT_ASKPASS:-}" == "${SCRIPT_DIR}/github-auth-askpass.sh" ]] || return 1
	[[ "${GIT_TERMINAL_PROMPT:-}" == "0" ]] || return 1
	return 0
}

cleanup_headless_git_auth() {
	local token_file="${AIDEVOPS_GIT_AUTH_TOKEN_FILE:-}"
	local token_helper="${SCRIPT_DIR}/worker-token-helper.sh"
	if [[ -n "$token_file" && -x "$token_helper" ]]; then
		"$token_helper" revoke --token-file "$token_file" >/dev/null 2>&1 || true
	fi
	unset AIDEVOPS_GIT_AUTH_TOKEN_FILE AIDEVOPS_GIT_AUTH_EXPECTED_ORIGIN
	unset GIT_ASKPASS GIT_TERMINAL_PROMPT GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL
	unset GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL _AIDEVOPS_HEADLESS_GIT_AUTH_ENV_CONFIGURED
	return 0
}

build_sandbox_passthrough_csv() {
	local provider="${1:-}"
	local role="${2:-worker}"
	local scoped_auth_ready="${3:-0}"
	local names=()
	local seen_names=" "
	local name

	while IFS='=' read -r name _; do
		if _headless_private_workload_enabled; then
			case "$name" in
			XDG_CACHE_HOME | XDG_CONFIG_HOME | XDG_DATA_HOME | XDG_STATE_HOME)
				names+=("$name")
				;;
			esac
			continue
		fi
		if [[ "$role" == "triage" || "$role" == "model-replay" ]]; then
			# Prefer the isolated provider entry over ambient credentials. This
			# prevents a stale API key from overriding a copied OAuth session while
			# preserving environment-only authentication when no entry was copied.
			if [[ "$scoped_auth_ready" != "1" && -n "$provider" ]] &&
				_headless_triage_provider_env_allowed "$provider" "$name"; then
				names+=("$name")
				continue
			fi
			case "$name" in
			AIDEVOPS_HEADLESS | AIDEVOPS_HEADLESS_AUTH_ISOLATION | AIDEVOPS_SESSION_ORIGIN | OPENCODE_DISABLE_CLAUDE_CODE_SKILLS | OPENCODE_DISABLE_EXTERNAL_SKILLS | OPENCODE_PURE | XDG_CACHE_HOME | XDG_CONFIG_HOME | XDG_DATA_HOME | XDG_STATE_HOME)
				names+=("$name")
				;;
			OPENCODE_CONFIG | OPENCODE_CONFIG_DIR | OPENCODE_DISABLE_AUTOCOMPACT | OPENCODE_DISABLE_AUTOUPDATE | OPENCODE_DISABLE_CLAUDE_CODE | OPENCODE_DISABLE_CLAUDE_CODE_PROMPT | OPENCODE_DISABLE_LSP_DOWNLOAD | OPENCODE_DISABLE_MODELS_FETCH | OPENCODE_DISABLE_PROJECT_CONFIG | OPENCODE_DISABLE_SHARE)
				[[ "$role" == "model-replay" ]] && names+=("$name")
				;;
			esac
			continue
		fi
		case "$name" in
		# Session-bound OpenCode env makes isolated canary/worker runs attach to
		# the parent TUI session and fail with "Session not found" (GH#23065).
		AIDEVOPS_OPENCODE_SESSION_ID | OPENCODE_SESSION_ID | OPENCODE_PID | OPENCODE_RUN_ID | OPENCODE_PROCESS_ROLE | OPENCODE | OPENCODE_SERVER_PASSWORD) continue ;;
		OPENAI_* | ANTHROPIC_* | GOOGLE_* | CLAUDE_*)
			if [[ -n "$provider" ]] && ! _headless_provider_env_allowed "$provider" "$name"; then
				continue
			fi
			;;
		# Permission and blocker tooling needs this bounded worker identity set.
		# Keep it explicit: arbitrary WORKER_* values may carry unrelated runtime
		# configuration and must not cross the clean sandbox boundary.
		WORKER_ISSUE_NUMBER | WORKER_REPO_SLUG | DISPATCH_REPO_SLUG | WORKER_SESSION_KEY | WORKER_WORKTREE_PATH | WORKER_GITHUB_LOGIN) ;;
		# Only the normalized signing-specific process config may cross the
		# sandbox boundary; arbitrary ambient GIT_CONFIG_* remains excluded.
		GIT_CONFIG_COUNT | GIT_CONFIG_KEY_0 | GIT_CONFIG_VALUE_0 | GIT_CONFIG_KEY_1 | GIT_CONFIG_VALUE_1 | GIT_CONFIG_KEY_2 | GIT_CONFIG_VALUE_2)
			_headless_signing_sandbox_env_is_normalized || continue
			;;
		GIT_ASKPASS | GIT_TERMINAL_PROMPT | GIT_AUTHOR_NAME | GIT_AUTHOR_EMAIL | GIT_COMMITTER_NAME | GIT_COMMITTER_EMAIL)
			_headless_git_auth_sandbox_env_is_normalized || continue
			;;
		# OTEL_* is passed through so headless workers under the sandbox
		# can export OTLP traces when OTEL_EXPORTER_OTLP_ENDPOINT is set.
		# Without this, opencode never initialises its OTLP exporter and
		# all aidevops.* plugin span enrichment is silently dropped (t2186).
		AIDEVOPS_* | PULSE_* | GH_* | GITHUB_* | OPENCODE_* | XDG_* | OTEL_* | REAL_HOME | TMPDIR | TMP | TEMP | RTK_* | VERIFY_*) ;;
		*) continue ;;
		esac
		if [[ "$seen_names" == *" ${name} "* ]]; then
			continue
		fi
		seen_names+="${name} "
		names+=("$name")
	done < <(env)

	local IFS=,
	printf '%s' "${names[*]}"
	return 0
}

# --- Section 7: Worker Contract ---

# append_worker_headless_contract: append unattended continuation rules to
# worker /full-loop prompts without changing interactive /full-loop behavior.
#
# This contract is injected at dispatch time by the headless runtime wrapper,
# so full-loop.md can remain dual-purpose (interactive + headless).
#
# Args: $1 = prompt text
# Output: prompt text (possibly appended)
# Env:
#   AIDEVOPS_HEADLESS_APPEND_CONTRACT=0 disables prompt augmentation.
_worker_headless_contract_setup_text() {
	cat <<'EOF'
[HEADLESS_CONTINUATION_CONTRACT_V9]
This is a HEADLESS worker session. No user is present. No user input is available.
You must drive autonomously to completion or an evidence-backed BLOCKED outcome.

Setup shortcuts -- the dispatcher has already done these for you:
- Your worktree is pre-created. $WORKER_WORKTREE_PATH contains the path. You are
  already in a safe linked worktree. Do NOT call pre-edit-check.sh,
  worktree-helper.sh, or session-rename tools under any circumstances.
  Pre-creation is guaranteed by the dispatcher (GH#21353 / t2983 Fix C). If
  WORKER_WORKTREE_PATH is unset, the headless runtime has already aborted — you
  are not running. Do NOT attempt to create a worktree yourself.
- Do NOT call aidevops-update-check.sh -- it exits immediately for headless workers.
- Do NOT call session-rename or session-rename_sync_branch -- your session title
  is already set by the dispatcher with the issue marker and issue title first
  (for example, `Issue #123: Fix dispatch title prefix`).

Key framework file paths (use these directly, do NOT search for them):
- Normal project repos: full-loop workflow is deployed at ~/.aidevops/agents/scripts/commands/full-loop.md
- Normal project repos: aidevops framework scripts live under ~/.aidevops/agents/scripts/ (not project-local .agents/scripts/)
- Aidevops source repo only: the same files are edited at .agents/scripts/commands/full-loop.md and under .agents/scripts/

Implementation approach:
1. Read the issue body FIRST (gh issue view "$WORKER_ISSUE_NUMBER" --repo "$WORKER_REPO_SLUG" --json body --jq '.body // ""'). Look for a "Worker Guidance" or "How" section -- it contains the files to modify, reference patterns, and verification commands. Follow these directly when present.
2. If Worker Guidance/How is missing or incomplete, do bounded discovery instead of stopping: use the issue title/body, exact error text, nearby helper names, tests, and git history to identify likely target files. Proceed when expected behavior, target area, and safe verification are clear.
3. Auto-generated "Unactioned Review Feedback" / quality-debt issues are not missing context solely because they lack file paths. Treat Source PR + captured review text as reproduction context; first verify whether the review is actionable, already fixed, or positive-only scanner noise, then implement a scanner/test fix or record a no-code resolution with evidence as the repo policy allows.
4. Budget discipline: spend at most 25% of your effort on reading/exploring. After reading the issue body + 2-3 likely reference files, start writing code. Do not read entire helper scripts -- read only the sections you will modify.
5. Exit BLOCKED with reason "missing implementation context" only after bounded discovery still cannot identify expected behavior, target area, or safe verification. Include what you searched and why it remains unsafe. The runtime will attempt one linked-issue brief-recovery continuation before recording this blocker.

Progressive context loading:
- Treat the issue body's Worker Guidance / How section as the authoritative plan.
- Load only referenced workflow/reference docs whose trigger matches your task.
- Prefer exact sections or line ranges over whole-file reads for large docs/scripts.
- Use any "Progressive Context Plan" as the read order: Read first, Load only if, Why, Stop when.
- Stop reading once target files, reference pattern, constraints, and verification are clear.
- If 3+ docs are cited without a priority plan, follow Worker Quick-Start and target files first; BLOCKED is valid only if ambiguity remains after that bounded read.

Empty tool results:
If a tool call returns empty output, it usually means the path or pattern was wrong, not that the resource is missing. Common causes: missing .agents/ prefix on paths, wrong glob pattern, file moved/renamed. Retry with corrected paths before giving up. If retries also fail, log what you tried and continue with the next step. Do NOT stop the session over one empty result.

Worktree edit verification (GH#22816):
After any file edit in the pre-created linked worktree, verify the worktree path still exists and the change is visible before claiming success or pushing. Minimum evidence: git status --short --branch from $WORKER_WORKTREE_PATH plus a diff/stat or commit containing the edited files. If the worktree or edits disappeared, reconstruct from available evidence before reporting completion.

Incremental WIP commits (GH#23677):
- Make a local WIP commit as soon as the first meaningful edit is coherent, then after each logical change. Use conventional WIP subjects such as `wip: preserve cleanup safety` until the final squash/PR commit.
- Do not leave valuable work only as dirty files while continuing to explore. A first WIP commit makes the worktree cleanup-visible as active real work even before a PR exists, and gives the runtime/watchdog a reachable commit to push or recover.
- If a commit hook blocks a WIP commit, fix the issue when practical; otherwise preserve the diff with a clear BLOCKED outcome rather than resetting or continuing with unprotected dirty state.
EOF
	return 0
}

_worker_headless_contract_execution_text() {
	cat <<'EOF'

Commit and PR shortcut:
After implementing, use full-loop-helper.sh commit-and-pr to collapse commit+push+PR+merge-summary into one call:
  PR_NUMBER=$(full-loop-helper.sh commit-and-pr --issue $WORKER_ISSUE_NUMBER --message "feat: description" --summary "what was done" --testing "how verified")
Then make one merge attempt: full-loop-helper.sh merge "$PR_NUMBER"
Exception: if your changes modify full-loop-helper.sh or its sourced helper libraries, commit first and then merge with the committed worktree helper path:
  "$PWD/.agents/scripts/full-loop-helper.sh" merge "$PR_NUMBER" "${GITHUB_REPOSITORY:-marcusquinn/aidevops}"
This verifies the code that will ship instead of the deployed helper copy from PATH.

Mandatory behavior:
4. Never ask for user confirmation, approval, or next steps. No user will respond.
5. Never emit user-directed language ("If you want...", "Let me know...", "Should I...").
6. Reading the issue and reading docs are SETUP -- not completion. You MUST continue through implementation, commit, push, and PR creation after setup.
7. A draft PR is only a durable checkpoint, never completion. Continue until the implementation and required local verification are complete, every intended commit is pushed, the PR is non-draft, the PR head matches local HEAD, and the required MERGE_SUMMARY exists.
8. Attempt the merge path once. If it merges, finish the required closing comments. If the exact-head non-draft PR has no terminal check failure and only asynchronous CI, review-bot, human approval, or native auto-merge remains, emit POST_PR_HANDOFF on its own line and exit normally. Pulse/webhook automation owns subsequent monitoring. Do not sleep, wait, or poll for those gates, and never bypass, disable, or weaken branch protection, approval, review-bot, CI, or security gates.
9. Model escalation before BLOCKED (GH#14964): BLOCKED is only valid after exhausting all autonomous solution paths. If the only remaining blocker is the current model's inability to reason through the task safely, emit `BLOCKED: capability limit - <evidence>`; runtime routing will retry at the next configured capability tier. Never use that marker for permission, authentication, provider, rate-limit, secret, policy, trust-boundary, or locality failures. Review-policy metadata and nominal GitHub states are NOT valid blockers. Genuine blockers require evidence: a failing check that cannot be repaired, missing permission, unresolved conflict, or explicit policy gate.

Terminal blocker reason protocol (GH#31239):
When genuinely blocked, put BLOCKED: <evidence> and exactly one standalone
reason line in the SAME final assistant text message (not a tool result):
TERMINAL_BLOCKER_REASON=missing_files_scope
Use that reason only when the canonical ## Files Scope or ### Files Scope
heading is absent; the runtime independently verifies the current issue body.
When the heading exists but a directly necessary integration file is excluded:
TERMINAL_BLOCKER_REASON=files_scope_excluded
Scope exclusion re-arms only on a corrected brief or an authorized explicit retry,
never on unrelated base commits. Identify the missing path and required verification
in the protected dossier; the AI brief owner must resolve the scope decision.
For an evidenced target-code defect or conflict that cannot be repaired within
the authorized scope, use this alternative reason line:
TERMINAL_BLOCKER_REASON=target_code_blocker
Target-code blockers may re-arm when the brief, dependencies, or target revision
changes. Never use that class for permissions, credentials, provider failures,
capability limits, missing/excluded scope, or ambiguous evidence. If no class is
established, omit the reason line: unknown evidence stays retryable, not held.
Do not invent classes or emit multiple reason lines. Keep raw stderr, private paths, secrets,
and sensitive evidence in protected telemetry; public recovery messages are
runtime-generated from allowlisted reason/action text, never copied model prose.

Activity watchdog constraint -- CRITICAL:
A continuous watchdog monitors your output. If you produce no tool calls or text
output for 300 seconds, you will be killed. Therefore:
  - NEVER use sleep/wait/poll longer than 240 seconds.
  - Do not use worker-driven polling to wait for post-PR CI or reviews. Perform one
    immediate state check, act on terminal failures, or hand off pending gates.
  - Before PR handoff, any required bounded wait must have an actionable result
    within this invocation and include status output before each wait.
EOF
	return 0
}

_worker_headless_contract_exit_text() {
	cat <<'EOF'

GitHub API fallback discipline:
If a command reports `GraphQL: API rate limit already exceeded`, do NOT stop
immediately and do NOT keep retrying GraphQL-backed `gh issue/pr list/view`
commands. First run `gh api rate_limit`. If REST core budget remains, continue
with REST-backed `gh api -X GET repos/...` requests for issues, comments, PRs,
checks, and labels where possible. If GraphQL reset is soon, wait in bounded
chunks (sleep <= 240s) with status output before each wait; otherwise continue
implementation from the issue body already supplied by the dispatcher and local
repo state. Commit safe local changes before waiting/retrying PR creation. Exit
BLOCKED only when the required remaining operation is GraphQL-only and the reset
time exceeds the safe worker runtime budget.

Pre-exit self-check -- MANDATORY:
Before ending your session, verify ALL of these:
  - At least one commit with implementation changes exists on your branch.
  - A PR exists for your branch: run gh pr list --head YOUR_BRANCH_NAME
  - The PR is non-draft, local HEAD is pushed and equals the PR headRefOid, and
    required local verification has passed. A draft or unpushed local commit is
    an incomplete checkpoint, not a successful handoff.
  - A MERGE_SUMMARY comment exists on the PR (full-loop step 4.2.1). Verify: gh api "repos/${REPO}/issues/${PR_NUMBER}/comments" --jq '[.[] | select(.body | test("<!-- MERGE_SUMMARY -->"))] | length' returns 1. If 0, post it now -- the merge pass uses it for closing comments.
  - Check remote state once. Terminal failures are worker-actionable and must not
    be reported as a successful handoff; pending CI/review alone is handed off.
  - If any readiness check fails, you are NOT done -- continue working.
  - Valid exit states are FULL_LOOP_COMPLETE, POST_PR_HANDOFF, or
    BLOCKED with evidence. Runtime classification independently validates PR state.
EOF
	return 0
}

_worker_headless_contract_text() {
	_worker_headless_contract_setup_text
	_worker_headless_contract_execution_text
	_worker_headless_contract_exit_text
	return 0
}

append_worker_headless_contract() {
	local prompt_text="$1"
	local append_enabled="${AIDEVOPS_HEADLESS_APPEND_CONTRACT:-1}"

	if [[ "$append_enabled" == "0" ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	if [[ "$prompt_text" != *"/full-loop"* ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	if [[ "$prompt_text" == *"HEADLESS_CONTINUATION_CONTRACT_V"* ]]; then
		printf '%s' "$prompt_text"
		return 0
	fi

	printf '%s\n\n' "$prompt_text"
	_worker_headless_contract_text
	return 0
}

# --- Section 8: Activity Watchdog (inline fallback) ---

#######################################
# Return whether output contains a known provider/rate-limit marker.
# Returns: 0 if a marker is present, 1 otherwise.
#######################################
_activity_output_has_provider_rate_limit() {
	local output_file="$1"
	[[ -f "$output_file" ]] || return 1
	grep -Eqi 'rate[ -]?limit|too many requests|http[[:space:]]*429|status[=: ][[:space:]]*429|quota exceeded|overloaded_error|provider.*(failed|unavailable)' "$output_file" 2>/dev/null
}

#######################################
# Return whether output shows an intentional CI/review wait.
# Returns: 0 if a marker is present, 1 otherwise.
#######################################
_activity_output_has_ci_wait() {
	local output_file="$1"
	[[ -f "$output_file" ]] || return 1
	grep -Eqi 'gh pr checks|review-bot-gate|pre-merge-gate|CI check|checks? (are )?(still )?(running|pending)|waiting (for|on) (CI|checks|review|merge)|merge (is )?(slow|pending)' "$output_file" 2>/dev/null
}

#######################################
# Handle a Phase 2 quiet-window threshold crossing.
# Returns: 0 if watchdog action is complete, 1 if caller should defer.
#######################################
_activity_watchdog_handle_stall() {
	local output_file="$1"
	local worker_pid="$2"
	local exit_code_file="$3"
	local session_key="$4"
	local stall_seconds="$5"
	local current_size="$6"
	local start_epoch="$7"
	local hard_kill_seconds="$8"

	local now_epoch elapsed_total
	now_epoch=$(date +%s)
	elapsed_total=$((now_epoch - start_epoch))

	if [[ "$hard_kill_seconds" -gt 0 && "$elapsed_total" -ge "$hard_kill_seconds" ]]; then
		_watchdog_kill "$worker_pid" "$exit_code_file" "$output_file" \
			"hard_kill: stall confirmed and total elapsed ${elapsed_total}s ≥ hard-kill threshold ${hard_kill_seconds}s (stuck at ${current_size}b) -- slot freed for re-dispatch" \
			"$session_key" "stall_killed"
		return 0
	fi
	if _activity_output_has_provider_rate_limit "$output_file"; then
		_watchdog_kill "$worker_pid" "$exit_code_file" "$output_file" \
			"provider_rate_limit: provider/rate-limit marker visible after ${stall_seconds}s stall (stuck at ${current_size}b, total elapsed ${elapsed_total}s)" "$session_key"
		return 0
	fi
	if _activity_output_has_ci_wait "$output_file"; then
		print_warning "Activity watchdog: CI-wait evidence found after ${stall_seconds}s quiet window -- deferring kill until hard backstop"
		return 1
	fi
	_watchdog_kill "$worker_pid" "$exit_code_file" "$output_file" \
		"stall: no output growth for ${stall_seconds}s (stuck at ${current_size}b, total elapsed ${elapsed_total}s)" "$session_key"
	return 0
}

#######################################
# Activity watchdog for _invoke_opencode.
#
# Runs as a background process alongside the worker. Polls the output file for
# growth. Timing thresholds are recovery backstops, not strict success/failure
# policy: output-active and CI-wait states continue, while the hard elapsed
# threshold applies only after a confirmed stall. Explicit provider failures
# recover promptly.
#
# The initial output always contains the sandbox startup line (~300 bytes).
# This is NOT activity -- it's just the executor logging. Real activity
# starts when the LLM responds with structured JSON events.
#
# Args:
#   $1 - output file path
#   $2 - worker PID to kill on timeout
#   $3 - exit code file (written with 124 on timeout)
#######################################
_run_activity_watchdog() {
	local output_file="$1"
	local worker_pid="$2"
	local exit_code_file="$3"
	local session_key="${4:-}"
	local stall_timeout="${HEADLESS_ACTIVITY_TIMEOUT_SECONDS:-600}"
	[[ "$stall_timeout" =~ ^[0-9]+$ ]] || stall_timeout=600

	# GH#17549: Continuous activity watchdog.
	#
	# Phase 1 (startup, default 180s): any output at all. Zero bytes = dead runtime.
	# Phase 2 (continuous): monitors file growth. If the output file stops
	#   growing for stall_timeout seconds, classify the stall before killing it.
	#
	# Previous design (broken): returned 0 after first LLM activity event,
	# never monitoring again. Workers that stalled mid-session were invisible.
	local phase1_timeout="${HEADLESS_PHASE1_TIMEOUT_SECONDS:-180}"
	[[ "$phase1_timeout" =~ ^[0-9]+$ ]] || phase1_timeout=180

	# t2956 / Issue #21231: Hard-kill threshold (default 1500s = 25 min).
	# When stall is detected AND total elapsed since watchdog start ≥ this,
	# escalate from passive kill (78 / continue) to proactive hard-kill
	# (79 / killed) — slot freed for re-dispatch instead of held through
	# repeated continuations. Set 0 to disable (legacy behaviour).
	local hard_kill_seconds="${WORKER_STALL_HARD_KILL_SECONDS:-1500}"
	[[ "$hard_kill_seconds" =~ ^[0-9]+$ ]] || hard_kill_seconds=1500

	local poll_interval=10
	local phase1_passed=0
	local phase1_elapsed=0
	local last_size=0
	local stall_seconds=0
	# t2956: Wall-clock start so hard_kill_seconds is measured against the
	# total time the watchdog has been monitoring this worker.
	local start_epoch
	start_epoch=$(date +%s)

	while true; do
		# Worker exited on its own -- watchdog not needed
		if ! kill -0 "$worker_pid" 2>/dev/null; then
			return 0
		fi

		local current_size=0
		if [[ -f "$output_file" ]]; then
			current_size=$(wc -c <"$output_file" 2>/dev/null || echo "0")
			current_size="${current_size##* }"
		fi

		# Phase 1: any output at all
		if [[ "$phase1_passed" -eq 0 ]]; then
			if [[ "$current_size" -gt 0 ]]; then
				phase1_passed=1
				last_size="$current_size"
				stall_seconds=0
			else
				phase1_elapsed=$((phase1_elapsed + poll_interval))
				if [[ "$phase1_elapsed" -ge "$phase1_timeout" ]]; then
					_watchdog_kill "$worker_pid" "$exit_code_file" "$output_file" \
						"phase1: zero output in ${phase1_timeout}s -- runtime failed to start" "$session_key"
					return 0
				fi
			fi
			sleep "$poll_interval"
			continue
		fi

		# Phase 2: continuous growth monitoring
		if [[ "$current_size" -gt "$last_size" ]]; then
			# File is growing -- worker is output-active
			last_size="$current_size"
			stall_seconds=0
		else
			# No growth -- increment stall counter
			stall_seconds=$((stall_seconds + poll_interval))
		fi

		if [[ "$stall_seconds" -ge "$stall_timeout" ]]; then
			if ! _activity_watchdog_handle_stall "$output_file" "$worker_pid" "$exit_code_file" \
				"$session_key" "$stall_seconds" "$current_size" "$start_epoch" "$hard_kill_seconds"; then
				stall_seconds=0
				sleep "$poll_interval"
				continue
			fi
			return 0
		fi

		sleep "$poll_interval"
	done
}

#######################################
# Kill a stalled worker and all its children.
# Extracted from _run_activity_watchdog for reuse by both phases.
#
# Args:
#   $1 - worker PID
#   $2 - exit code file
#   $3 - output file
#   $4 - reason string (logged)
#   $5 - session key (optional)
#   $6 - kill kind (optional): "stall_killed" emits the additional
#        .watchdog_stall_killed sentinel for hard-kill classification
#        (exit 79 / watchdog_stall_killed) per t2956 / Issue #21231.
#        Empty/anything else preserves the legacy 78 / watchdog_stall_continue
#        path so callers that don't pass a kill kind keep working.
#
# Exit code conventions consumed by `headless-runtime-helper.sh`:
#   - exit_code_file always written as 124 (timeout convention).
#   - .watchdog_killed sentinel always written before SIGTERM (race-safe).
#   - .watchdog_stall_killed sentinel ONLY written when $kill_kind ==
#     "stall_killed" — caller maps to helper exit 79 (no continuation,
#     slot freed) instead of 78 (stall-continue retry).
#######################################
_watchdog_kill() {
	local worker_pid="$1"
	local exit_code_file="$2"
	local output_file="$3"
	local reason="$4"
	local session_key="${5:-}"
	local kill_kind="${6:-}"

	print_warning "Activity watchdog: ${reason} -- killing worker (PID $worker_pid)"
	# Write the marker BEFORE killing -- the dying subshell may overwrite
	# exit_code_file with its own exit code (race condition). The marker
	# file survives because only the watchdog writes to it.
	touch "${exit_code_file}.watchdog_killed"
	printf '%s\n' "no_output_stall" >"${exit_code_file}.kill_reason" 2>/dev/null || true
	# t2956 / Issue #21231: Hard-kill sentinel for proactive elapsed-time
	# kills. Helper reads this and returns 79 instead of 78 — no continuation,
	# slot freed for re-dispatch. The .watchdog_killed sentinel is still
	# written above so existing exit-code-124 detection paths keep working.
	if [[ "$kill_kind" == "stall_killed" ]]; then
		touch "${exit_code_file}.watchdog_stall_killed"
		printf '%s\n' "hard_kill_stall" >"${exit_code_file}.kill_reason" 2>/dev/null || true
	fi
	# Kill child processes first (pipeline members: opencode, tee), then
	# the subshell itself. pkill -P walks the process tree by PPID.
	pkill -P "$worker_pid" 2>/dev/null || true
	kill "$worker_pid" 2>/dev/null || true
	sleep 2
	pkill -9 -P "$worker_pid" 2>/dev/null || true
	kill -9 "$worker_pid" 2>/dev/null || true
	printf '124' >"$exit_code_file"
	printf '\n[WATCHDOG_KILL] timestamp=%s worker_pid=%s reason="%s"\n' \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$worker_pid" "$reason" >>"$output_file" 2>/dev/null || true

	# Release the dispatch claim so the issue is immediately available
	# for re-dispatch instead of waiting for the 30-min TTL.
	if [[ -n "$session_key" ]]; then
		_release_dispatch_claim "$session_key" "watchdog_kill:${reason}"
	fi
	return 0
}

# --- Sub-library sourcing ---
# Database lifecycle (Section 9)
# shellcheck source=./headless-runtime-database.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-database.sh"

# --- Section 10: Dispatch Ledger / Session Locks ---

# _register_dispatch_ledger: register this dispatch in the in-flight ledger (GH#6696).
# Extracts issue number from session_key (pattern: "issue-NNN") and registers
# the dispatch so the pulse can detect in-flight workers before they create PRs.
#
# Args: $1 = session_key, $2 = work_dir (used to resolve repo slug)
_register_dispatch_ledger() {
	local ledger_session_key="$1"
	local ledger_work_dir="$2"

	[[ -x "$DISPATCH_LEDGER_HELPER" ]] || return 0

	local ledger_issue=""
	local ledger_repo=""

	# Extract issue number from session key (e.g., "issue-42" -> "42")
	if [[ "$ledger_session_key" =~ ^issue-([0-9]+)$ ]]; then
		ledger_issue="${BASH_REMATCH[1]}"
	fi

	# Resolve repo slug from work_dir via git remote
	if [[ -n "$ledger_work_dir" && -d "$ledger_work_dir" ]]; then
		ledger_repo=$(git -C "$ledger_work_dir" remote get-url origin 2>/dev/null | sed -E 's|.*[:/]([^/]+/[^/]+)(\.git)?$|\1|' || true)
	fi

	local ledger_args=(register --session-key "$ledger_session_key" --pid "$$")
	if [[ -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" ]]; then
		ledger_args+=(--lease-token "$AIDEVOPS_DISPATCH_LEASE_TOKEN" --device-id "${AIDEVOPS_DISPATCH_LEASE_DEVICE:-}")
	fi
	[[ -n "$ledger_issue" ]] && ledger_args+=(--issue "$ledger_issue")
	[[ -n "$ledger_repo" ]] && ledger_args+=(--repo "$ledger_repo")
	[[ -n "$ledger_work_dir" ]] && ledger_args+=(--worktree "$ledger_work_dir")
	[[ -n "${AIDEVOPS_DISPATCH_TIER:-}" ]] && ledger_args+=(--tier "$AIDEVOPS_DISPATCH_TIER")
	[[ -n "${AIDEVOPS_DISPATCH_MODEL:-}" ]] && ledger_args+=(--model "$AIDEVOPS_DISPATCH_MODEL")
	[[ -n "${AIDEVOPS_ATTEMPT_ID:-}" ]] && ledger_args+=(--attempt-id "$AIDEVOPS_ATTEMPT_ID")
	if [[ -n "${AIDEVOPS_ATTEMPT_STATE_ROOT:-}" && -n "${AIDEVOPS_ATTEMPT_STATE_FILE:-}" &&
		-n "${AIDEVOPS_HEADLESS_OUTCOME_FILE:-}" ]]; then
		ledger_args+=(
			--attempt-state-root "$AIDEVOPS_ATTEMPT_STATE_ROOT"
			--attempt-state-file "$AIDEVOPS_ATTEMPT_STATE_FILE"
			--outcome-file "$AIDEVOPS_HEADLESS_OUTCOME_FILE"
		)
	fi

	"$DISPATCH_LEDGER_HELPER" "${ledger_args[@]}" 2>/dev/null || true
	return 0
}

# _update_dispatch_ledger: mark a dispatch as completed or failed (GH#6696).
# Args: $1 = session_key, $2 = status ("completed" or "failed")
_update_dispatch_ledger() {
	local ledger_session_key="$1"
	local ledger_status="$2"

	[[ -x "$DISPATCH_LEDGER_HELPER" ]] || return 0

	local -a ledger_args=("$ledger_status" --session-key "$ledger_session_key")
	[[ -n "${AIDEVOPS_DISPATCH_LEASE_TOKEN:-}" ]] && ledger_args+=(--lease-token "$AIDEVOPS_DISPATCH_LEASE_TOKEN")
	[[ -n "${AIDEVOPS_ATTEMPT_ID:-}" ]] && ledger_args+=(--attempt-id "$AIDEVOPS_ATTEMPT_ID")
	"$DISPATCH_LEDGER_HELPER" "${ledger_args[@]}" 2>/dev/null || true
	return 0
}

# _acquire_session_lock: prevent duplicate workers for the same session-key (GH#6538).
#
# Creates a PID lock file at $LOCK_DIR/<session_key>.pid. If a lock file
# already exists with a live PID, returns 1 (duplicate -- caller should exit).
# If the PID is dead, cleans up the stale lock and acquires a new one.
#
# Args: $1 = session_key
# Returns: 0 = lock acquired, 1 = duplicate detected (live process exists)
_acquire_session_lock() {
	local lock_session_key="$1"
	mkdir -p "$LOCK_DIR" 2>/dev/null || true

	# Sanitise session key for use as filename (replace / and spaces)
	local safe_key
	safe_key=$(printf '%s' "$lock_session_key" | tr '/ ' '__')
	local lock_file="${LOCK_DIR}/${safe_key}.pid"

	if [[ -f "$lock_file" ]]; then
		# t2421: format is "pid|argv_hash" — parse both fields (backward-compat with bare pid)
		local existing_raw existing_pid existing_hash
		existing_raw=$(cat "$lock_file" 2>/dev/null) || existing_raw=""
		existing_pid="${existing_raw%%|*}"
		existing_hash="${existing_raw#*|}"
		[[ "$existing_hash" == "$existing_pid" ]] && existing_hash=""  # no | separator = legacy format
		if [[ -n "$existing_pid" ]] && [[ "$existing_pid" =~ ^[0-9]+$ ]]; then
			# t2421: command-aware liveness — bare kill -0 lies on macOS PID reuse
			if _is_process_alive_and_matches "$existing_pid" "${WORKER_PROCESS_PATTERN:-}" "$existing_hash"; then
				# Live worker process exists -- duplicate dispatch
				print_warning "Duplicate dispatch blocked: session-key '${lock_session_key}' already has active worker PID ${existing_pid} (GH#6538/t2421)"
				return 1
			fi
			# PID is dead or reused by unrelated process -- stale lock, clean up and proceed
		fi
		rm -f "$lock_file"
	fi

	# nice -- lock acquired, this session key is ours
	# t2421: store pid|argv_hash for PID-reuse-resistant liveness checks
	local _hrl_argv_hash=""
	_hrl_argv_hash=$(_compute_argv_hash "$$" 2>/dev/null || echo "")
	printf '%s|%s' "$$" "$_hrl_argv_hash" >"$lock_file"
	return 0
}

# _release_session_lock: remove the PID lock file for a session-key.
# Only removes if the lock file contains our own PID (safety against races).
#
# Args: $1 = session_key
_release_session_lock() {
	local lock_session_key="$1"
	local safe_key
	safe_key=$(printf '%s' "$lock_session_key" | tr '/ ' '__')
	local lock_file="${LOCK_DIR}/${safe_key}.pid"

	if [[ -f "$lock_file" ]]; then
		local stored_raw stored_pid
		stored_raw=$(cat "$lock_file" 2>/dev/null) || stored_raw=""
		stored_pid="${stored_raw%%|*}"
		if [[ "$stored_pid" == "$$" ]]; then
			rm -f "$lock_file"
		fi
	fi
	return 0
}

_acquire_private_workload_lock() {
	local workload_lock_key="$1"
	local owner_hash=""
	local acquire_result=""
	local existing_raw=""
	local existing_pid=""
	local existing_hash=""
	local takeover_result=""

	[[ "$workload_lock_key" =~ ^private-workload-dir-[a-f0-9]{64}$ ]] || return 1
	owner_hash=$(_compute_argv_hash "$$" 2>/dev/null || printf '')
	[[ "$owner_hash" =~ ^[a-f0-9]{12}$ ]] || return 1

	acquire_result=$(sqlite3_with_timeout "$STATE_DB" \
		"BEGIN IMMEDIATE; INSERT OR IGNORE INTO private_workload_locks (lock_key, owner_pid, owner_argv_hash) VALUES ('${workload_lock_key}', $$, '${owner_hash}'); SELECT changes(); COMMIT;" \
		2>/dev/null) || return 1
	if [[ "$acquire_result" == "1" ]]; then
		return 0
	fi

	existing_raw=$(sqlite3_with_timeout "$STATE_DB" \
		"SELECT owner_pid || '|' || owner_argv_hash FROM private_workload_locks WHERE lock_key = '${workload_lock_key}' LIMIT 1;" \
		2>/dev/null) || return 1
	existing_pid="${existing_raw%%|*}"
	existing_hash="${existing_raw#*|}"
	if [[ ! "$existing_pid" =~ ^[0-9]+$ || ! "$existing_hash" =~ ^[a-f0-9]{12}$ ]]; then
		return 1
	fi
	if [[ "$existing_pid" == "$$" ]] || \
		_is_process_alive_and_matches "$existing_pid" "${FRAMEWORK_PROCESS_PATTERN:-}" "$existing_hash"; then
		print_warning "Duplicate private workload blocked: directory already has an active worker"
		return 1
	fi

	takeover_result=$(sqlite3_with_timeout "$STATE_DB" \
		"BEGIN IMMEDIATE; DELETE FROM private_workload_locks WHERE lock_key = '${workload_lock_key}' AND owner_pid = ${existing_pid} AND owner_argv_hash = '${existing_hash}'; INSERT OR IGNORE INTO private_workload_locks (lock_key, owner_pid, owner_argv_hash) VALUES ('${workload_lock_key}', $$, '${owner_hash}'); SELECT CASE WHEN owner_pid = $$ AND owner_argv_hash = '${owner_hash}' THEN 1 ELSE 0 END FROM private_workload_locks WHERE lock_key = '${workload_lock_key}'; COMMIT;" \
		2>/dev/null) || return 1
	[[ "$takeover_result" == "1" ]] || return 1
	return 0
}

_release_private_workload_lock() {
	local workload_lock_key="$1"

	[[ "$workload_lock_key" =~ ^private-workload-dir-[a-f0-9]{64}$ ]] || return 1
	sqlite3_with_timeout "$STATE_DB" \
		"DELETE FROM private_workload_locks WHERE lock_key = '${workload_lock_key}' AND owner_pid = $$;" \
		>/dev/null 2>&1 || return 1
	return 0
}

# --- Sub-library sourcing (GH#19699) ---
# Failure reporting (Section 11: dispatch claim + fast-fail)
# shellcheck source=./headless-runtime-failure.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-failure.sh"

# --- Section 12: Canary + Version Pin ---

# Module-level variable set by _validate_opencode_binary as a side-effect.
# Callers that need the version string after validation can read this instead
# of re-running "$bin" --version (avoids redundant I/O — GH#21003 finding 2).
_VALIDATE_OC_VERSION=""

CANARY_CACHE_TTL_SECONDS="${CANARY_CACHE_TTL_SECONDS:-1800}"
CANARY_TIMEOUT_SECONDS="${CANARY_TIMEOUT_SECONDS:-180}"
# t2814 (Phase 3, fix #4): Short-lived negative cache. When the canary
# fails, subsequent dispatch attempts within this window short-circuit to
# fail-fast instead of each spending up to CANARY_TIMEOUT_SECONDS on a
# canary that will fail for the same reason (auth token expired, rate
# limit, provider outage). Default 90s — long enough to absorb a typical
# auth/rate-limit blip, short enough to recover quickly when the
# underlying issue clears. The positive cache (1800s default) is
# unaffected; success always wins and clears the negative cache.
CANARY_NEGATIVE_TTL_SECONDS="${CANARY_NEGATIVE_TTL_SECONDS:-90}"

# t2887: Long backoff for STRUCTURAL config errors (wrong binary, missing
# binary, malformed config). Unlike transient API blips, structural errors
# do not self-resolve in 90s — they require either a runner upgrade
# (`aidevops update`) or maintainer intervention. Hammering an issue with
# DISPATCH_CLAIM/CLAIM_RELEASED comment pairs every 90s on a structurally
# broken runner destroys signal in issue threads (~120 spam comments/hour
# on alex-solovyev's runner pre-fix). 1h backoff reduces noise ~40x while
# still allowing recovery within a single pulse-update cycle.
CANARY_CONFIG_ERROR_TTL_SECONDS="${CANARY_CONFIG_ERROR_TTL_SECONDS:-3600}"

# t3558 (GH#22634): CPU/load/saturation is never a dispatch throttle.
# The OS scheduler should arbitrate CPU contention; local RAM/disk capacity,
# auth, provider availability, and runtime health are the meaningful launch
# constraints. Keep this deprecated variable for env compatibility only — it
# is no longer read by the negative-cache TTL logic.
CANARY_OVERLOAD_TTL_SECONDS="${CANARY_OVERLOAD_TTL_SECONDS:-300}"

# t3449: Soft canary failures (timeouts/provider/rate-limit blips) may be
# bypassed by the dispatcher only when there is recent worker evidence. Hard
# failures (auth/runtime/config/local) still block. This window bounds the
# bypass so a stale success cannot mask a real outage indefinitely.
CANARY_SOFT_FAILURE_RECENT_SUCCESS_TTL_SECONDS="${CANARY_SOFT_FAILURE_RECENT_SUCCESS_TTL_SECONDS:-900}"

# t3549/t3558: CPU/load checks are advisory-only. Load average is the wrong
# dispatch signal (counts uninterruptible-IO waits, inflates while CPU sits
# idle), and even real CPU saturation is not a useful launch blocker on a
# RAM-sufficient local runner. The canary tests runtime/model health only.
#
# CANARY_SATURATION_WINDOW_SECONDS / CANARY_SATURATION_PERCENT — deprecated
# env compatibility for the advisory cpu-saturation-helper.sh. The canary
# and dispatch path no longer read these values.
CANARY_SATURATION_WINDOW_SECONDS="${CANARY_SATURATION_WINDOW_SECONDS:-120}"
CANARY_SATURATION_PERCENT="${CANARY_SATURATION_PERCENT:-98}"

# t3549/t3558 (DEPRECATED): kept for env compatibility. CPU/load/saturation
# no longer affects canary preflight, classification, or dispatch throttling.
# Remove from any user shell profile that still exports it.
CANARY_OVERLOAD_LOAD_MULTIPLIER="${CANARY_OVERLOAD_LOAD_MULTIPLIER:-4}"

#######################################
# t2887: Validate that an opencode binary path is the real anomalyco/opencode.
#
# Distinguishes anomalyco/opencode (the intended runtime) from anthropic's
# `claude` CLI (`@anthropic-ai/claude-code`), which workers may have on
# PATH and which the canary cannot use because it does not accept
# opencode's `-m` flag.
#
# Signatures observed in the wild:
#   anomalyco/opencode --version  -> "1.14.25"          (semver only)
#   anthropic/claude --version    -> "2.1.120 (Claude Code)"
#
# Returns:
#   0 = valid anomalyco/opencode (semver-shaped, no Claude Code marker, major <= 1)
#   1 = wrong binary (Claude Code marker OR major version >= 2)
#   2 = missing or unrunnable binary
# Side-effect: sets _VALIDATE_OC_VERSION to the raw --version output (GH#21003).
#######################################
_validate_opencode_binary() {
	local bin="${1:-}"
	# GH#21505: clear side-effect variable first so callers never see a stale
	# version from a previous successful call when this invocation returns early.
	_VALIDATE_OC_VERSION=""
	[[ -n "$bin" ]] || return 2
	command -v "$bin" >/dev/null 2>&1 || return 2

	local version_output
	version_output=$("$bin" --version 2>/dev/null || echo "")
	[[ -n "$version_output" ]] || return 2

	# GH#21003: expose version to callers so they don't re-run --version.
	_VALIDATE_OC_VERSION="$version_output"

	# Anthropic claude CLI signature -- highest-confidence rejection
	[[ "$version_output" == *"(Claude Code)"* ]] && return 1

	# GH#21003: Extract major version as integer for robust comparison.
	# The previous regex ^[2-9][0-9]*\. missed two-digit majors like 10.x.
	local major="${version_output%%.*}"
	[[ "$major" =~ ^[0-9]+$ ]] && [[ "$major" -ge 2 ]] && return 1

	# Sanity check: must look like a semver (X.Y.Z)
	[[ "$version_output" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]] || return 1

	return 0
}

_headless_runtime_is_linux() {
	local platform="${AIDEVOPS_TEST_UNAME_S:-}"
	if [[ -z "$platform" ]]; then
		platform=$(uname -s 2>/dev/null || true)
	fi
	[[ "$platform" == "Linux" ]] && return 0
	return 1
}

_opencode_fixed_candidate_paths() {
	local fixed_candidates=(
		"/opt/homebrew/bin/opencode"
		"/usr/local/bin/opencode"
		"${HOME}/.local/bin/opencode"
		"${HOME}/.opencode/bin/opencode"
	)
	if _headless_runtime_is_linux; then
		fixed_candidates+=("/snap/bin/opencode")
	fi
	printf '%s\n' "${fixed_candidates[@]}"
	return 0
}

_opencode_fixed_candidate_dirs_for_warning() {
	local fixed_candidate_dirs="/opt/homebrew/bin, /usr/local/bin, ~/.local/bin, ~/.opencode/bin"
	if _headless_runtime_is_linux; then
		fixed_candidate_dirs="${fixed_candidate_dirs}, /snap/bin"
	fi
	printf '%s' "$fixed_candidate_dirs"
	return 0
}

#######################################
# t2887/t2954: Search common installation paths for a real anomalyco/opencode
# binary. Used as a self-heal when $OPENCODE_BIN_DEFAULT resolves to the
# wrong binary (alex-solovyev's runner: `opencode` first on PATH returned
# claude CLI). Echoes the first candidate that passes _validate_opencode_binary;
# returns 0 on success, 1 if no valid binary found. Caller plumbs the result
# through (export OPENCODE_BIN, set local _effective_opencode_bin) since
# $OPENCODE_BIN_DEFAULT is `readonly`.
#
# t2954 (Apr 2026): Node version manager paths (nvm, volta, fnm) added.
# nvm is overwhelmingly the most common Node manager on Linux; the
# absence of nvm here mirrored the gap in .agents/scripts/setup/modules/schedulers.sh
# and silently broke dispatch for ~9 days on alex-solovyev's runner
# every time the persisted scheduler-runtime-bin file got dropped or
# the canary fired against a freshly missing binary.
#######################################
_find_alternative_opencode_binary() {
	# Fixed install paths (Homebrew, npm-global, Snap, etc.).
	local candidate
	while IFS= read -r candidate; do
		if [[ -x "$candidate" ]] && _validate_opencode_binary "$candidate"; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done < <(_opencode_fixed_candidate_paths)

	# t2954: Node version manager sweep (nvm, volta, fnm). Newest version
	# wins (sort -rV) so users on multiple Node versions get the most-
	# recent opencode build by default.
	local nvm_root version_dir
	for nvm_root in \
		"${HOME}/.nvm/versions/node" \
		"${HOME}/.volta/tools/image/node" \
		"${HOME}/.local/share/fnm/node-versions"; do
		[[ -d "$nvm_root" ]] || continue
		while IFS= read -r version_dir; do
			# nvm + volta: <ver>/bin/opencode; fnm: <ver>/installation/bin/opencode
			for candidate in \
				"$version_dir/bin/opencode" \
				"$version_dir/installation/bin/opencode"; do
				if [[ -x "$candidate" ]] && _validate_opencode_binary "$candidate"; then
					printf '%s\n' "$candidate"
					return 0
				fi
			done
		done < <(find "$nvm_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort -rV)
	done

	return 1
}

#######################################
# Resolve the native OpenCode executable from an isolated npm prefix.
#######################################
_resolve_headless_opencode_install_binary() {
	local install_root="$1"
	local machine_arch="${AIDEVOPS_TEST_UNAME_M:-}"
	if [[ -z "$machine_arch" ]]; then
		machine_arch=$(uname -m 2>/dev/null || true)
	fi
	local package_arch=""
	case "$machine_arch" in
	x86_64 | amd64) package_arch="x64" ;;
	aarch64 | arm64) package_arch="arm64" ;;
	*) return 1 ;;
	esac

	local base="opencode-linux-${package_arch}"
	local suffixes=("")
	if [[ "$package_arch" == "x64" ]] && ! grep -qE '(^|[[:space:]])avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
		suffixes=("-baseline" "")
	fi
	if ldd --version 2>&1 | grep -qi musl; then
		if [[ "$package_arch" == "x64" ]]; then
			suffixes=("-musl" "-baseline-musl" "" "-baseline")
		else
			suffixes=("-musl" "")
		fi
	fi

	local suffix=""
	for suffix in "${suffixes[@]}"; do
		local binary="$install_root/node_modules/${base}${suffix}/bin/opencode"
		if [[ -x "$binary" ]]; then
			printf '%s\n' "$binary"
			return 0
		fi
	done
	return 1
}

#######################################
# Install an exact OpenCode release into an isolated, versioned prefix and
# publish it atomically. The runtime uses the normal HOME only after install so
# existing provider authentication remains available to workers.
#######################################
_provision_headless_opencode_runtime() {
	local pin="$1"
	local runtime_root="${STATE_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}/opencode-runtimes"
	local install_root="$runtime_root/$pin"
	local existing_bin=""
	if existing_bin=$(_resolve_headless_opencode_install_binary "$install_root" 2>/dev/null) &&
		_validate_opencode_binary "$existing_bin" && [[ "${_VALIDATE_OC_VERSION#v}" == "$pin" ]]; then
		HEADLESS_OPENCODE_BIN="$existing_bin"
		return 0
	fi

	command -v npm >/dev/null 2>&1 || {
		print_error "Cannot provision pinned OpenCode ${pin}: npm is unavailable"
		return 1
	}
	mkdir -p "$runtime_root" || return 1
	local temp_root="$runtime_root/.${pin}.install.$$"
	local isolated_home="$temp_root/home"
	local isolated_cache="$temp_root/cache"
	mkdir -p "$temp_root/prefix" "$isolated_home" "$isolated_cache" || return 1
	if ! env -i HOME="$isolated_home" PATH="$PATH" \
		GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
		npm_config_userconfig=/dev/null npm_config_cache="$isolated_cache" \
		npm install --ignore-scripts --no-audit --no-fund --prefix "$temp_root/prefix" \
		"opencode-ai@${pin}" >/dev/null 2>&1; then
		print_error "Failed to provision isolated OpenCode ${pin}; general installation was not changed"
		rm -rf "$temp_root"
		return 1
	fi
	local candidate_bin=""
	if ! candidate_bin=$(_resolve_headless_opencode_install_binary "$temp_root/prefix") ||
		! _validate_opencode_binary "$candidate_bin" || [[ "${_VALIDATE_OC_VERSION#v}" != "$pin" ]]; then
		print_error "Isolated OpenCode ${pin} failed exact-version verification"
		rm -rf "$temp_root"
		return 1
	fi

	local stale_root="$runtime_root/.${pin}.stale.$$"
	if [[ -e "$install_root" ]]; then
		mv "$install_root" "$stale_root" || {
			rm -rf "$temp_root"
			return 1
		}
	fi
	if ! mv "$temp_root/prefix" "$install_root"; then
		[[ ! -e "$stale_root" ]] || mv "$stale_root" "$install_root" 2>/dev/null || true
		rm -rf "$temp_root"
		return 1
	fi
	rm -rf "$temp_root" "$stale_root"
	HEADLESS_OPENCODE_BIN=$(_resolve_headless_opencode_install_binary "$install_root") || return 1
	print_info "OpenCode headless runtime ready at pinned version ${pin}"
	return 0
}

_clear_stale_opencode_pin_repair_lock() {
	local repair_lock_dir="$1"
	local pin="$2"
	local runtime_root="$3"
	local installer_pid=""
	local install_root=""
	local live_installer=0

	if [[ ! -d "$repair_lock_dir" ]]; then
		return 1
	fi
	for install_root in "$runtime_root"/."$pin".install.*; do
		[[ -e "$install_root" ]] || continue
		installer_pid="${install_root##*.install.}"
		if [[ "$installer_pid" =~ ^[0-9]+$ ]] && kill -0 "$installer_pid" 2>/dev/null; then
			live_installer=1
			continue
		fi
		rm -rf "$install_root"
	done
	if [[ "$live_installer" -eq 1 ]]; then
		return 1
	fi
	if rmdir "$repair_lock_dir" 2>/dev/null; then
		return 0
	fi
	return 1
}

#######################################
# Version guard -- bind affected worker launches to an isolated exact-version
# OpenCode runtime. General/interactive installs remain free to track latest.
#######################################
_enforce_opencode_version_pin() {
	local pin="${OPENCODE_PINNED_VERSION:-}"
	# No pin or pin is "latest" -> nothing to enforce
	if [[ -z "$pin" || "$pin" == "latest" ]]; then
		HEADLESS_OPENCODE_BIN="$OPENCODE_BIN_DEFAULT"
		return 0
	fi
	# The scheduled compatibility evaluator must exercise its isolated candidate,
	# not repair it back to the current pin before the canary starts.
	if [[ "${AIDEVOPS_OPENCODE_PIN_CANDIDATE_EVALUATION:-0}" == "1" ]]; then
		HEADLESS_OPENCODE_BIN="$OPENCODE_BIN_DEFAULT"
		return 0
	fi
	local pin_platform="${AIDEVOPS_OPENCODE_PIN_PLATFORM_OVERRIDE:-$(uname -s 2>/dev/null || printf 'unknown')}"
	if ! aidevops_opencode_pin_applies "$pin_platform" "headless"; then
		HEADLESS_OPENCODE_BIN="$OPENCODE_BIN_DEFAULT"
		return 0
	fi

	# Multiple Pulse candidates can hit the canary at once. Serialize isolated
	# provisioning so workers never race while publishing the pinned runtime.
	local repair_lock_base="${STATE_DIR:-${HOME}/.aidevops/.agent-workspace/headless-runtime}"
	local repair_lock_dir="${repair_lock_base}/opencode-pin-repair.lock"
	local runtime_root="${repair_lock_base}/opencode-runtimes"
	local repair_lock_wait_limit="${AIDEVOPS_OPENCODE_PIN_REPAIR_LOCK_WAIT_LIMIT:-30}"
	mkdir -p "$repair_lock_base" 2>/dev/null || true
	local repair_lock_acquired=0
	local repair_lock_waited=0
	while ! mkdir "$repair_lock_dir" 2>/dev/null; do
		if [[ "$repair_lock_waited" -ge "$repair_lock_wait_limit" ]]; then
			if _clear_stale_opencode_pin_repair_lock "$repair_lock_dir" "$pin" "$runtime_root"; then
				repair_lock_waited=0
				continue
			fi
			print_error "Timed out waiting for OpenCode ${pin} repair lock -- refusing headless launch"
			return 1
		fi
		sleep 1
		repair_lock_waited=$((repair_lock_waited + 1))
	done
	repair_lock_acquired=1

	if ! _provision_headless_opencode_runtime "$pin"; then
		print_error "OpenCode ${pin} isolated runtime provisioning failed -- refusing headless launch"
		[[ "$repair_lock_acquired" -eq 0 ]] || rmdir "$repair_lock_dir" 2>/dev/null || true
		return 1
	fi
	rmdir "$repair_lock_dir" 2>/dev/null || true
	return 0
}

# t3549/t3558: CPU/load/saturation must never gate dispatch. Load average
# inflates under uninterruptible IO waits, and CPU spikes are often caused by
# the pulse/runners themselves. The canary now always runs (modulo the
# existing negative cache and binary-validity checks) and timeout-class
# failures stay `timeout`; RAM/disk/provider/runtime checks are responsible
# for real launch blocking.
#
# This stub is retained for one release so existing callers and tests that
# invoke `_check_system_overload` continue to compile. It always returns
# success (0 = system OK, proceed). Remove in the release after t3549 ships.
_check_system_overload() {
	return 0
}

# t3558 (GH#22634): CPU saturation is advisory-only. Timeout-class canary
# exits classify as `timeout` regardless of load/CPU state so pulse/runner
# CPU spikes cannot lengthen dispatch backoff.
_classify_canary_failure_reason() {
	local output_file="$1"
	local exit_code="$2"
	local reason
	reason=$(classify_failure_reason "$output_file")
	case "$reason" in
		access_denied | auth_error | quota_exceeded | rate_limit | provider_error)
			printf '%s' "$reason"
			return 0
			;;
	esac
	case "$exit_code" in
		124 | 137 | 142)
			printf '%s' "timeout"
			return 0
			;;
		126 | 127)
			printf '%s' "runtime_error"
			return 0
			;;
	esac
	if [[ "$reason" == "local_error" ]]; then
		local lowered=""
		lowered=$(_read_failure_output_lowercase "$output_file")
		if ! _classify_local_runtime_failure "$lowered" >/dev/null; then
			printf '%s' "inconclusive"
			return 0
		fi
	fi
	printf '%s' "local_error"
	return 0
}

_record_canary_provider_backoff() {
	local canary_model="$1"
	local canary_reason="$2"
	local canary_output="$3"
	case "$canary_reason" in
	access_denied | auth_error | quota_exceeded | rate_limit | provider_error)
		local canary_provider
		canary_provider=$(extract_provider "$canary_model" 2>/dev/null || printf '%s' "")
		if [[ -n "$canary_provider" ]]; then
			record_provider_backoff "$canary_provider" "$canary_reason" "$canary_output" "$canary_model" || true
		fi
		;;
	*) ;;
	esac
	return 0
}

_canary_pass_cache_is_fresh() {
	local cache_file="$1"
	if [[ ! -f "$cache_file" ]]; then
		return 1
	fi
	local last_pass
	last_pass=$(cat "$cache_file" 2>/dev/null || echo "0")
	local now
	now=$(date +%s)
	local age=$((now - last_pass))
	if [[ "$age" -lt "$CANARY_CACHE_TTL_SECONDS" ]]; then
		return 0
	fi
	return 1
}

_canary_negative_cache_is_active() {
	local fail_cache_file="$1"
	local fail_reason_file="$2"
	if [[ "${AIDEVOPS_SKIP_CANARY_NEG_CACHE:-0}" == "1" ]] || [[ ! -f "$fail_cache_file" ]]; then
		return 1
	fi
	local last_fail
	local neg_now
	local neg_age
	local active_ttl
	local fail_reason
	last_fail=$(cat "$fail_cache_file" 2>/dev/null || echo "0")
	neg_now=$(date +%s)
	neg_age=$((neg_now - last_fail))
	fail_reason=$(cat "$fail_reason_file" 2>/dev/null || echo "transient")
	# t2887/t3558: Structural failures retain a longer negative-cache TTL;
	# CPU/load overload is intentionally not a distinct TTL class.
	case "$fail_reason" in
	config_error) active_ttl="$CANARY_CONFIG_ERROR_TTL_SECONDS" ;;
	*) active_ttl="$CANARY_NEGATIVE_TTL_SECONDS" ;;
	esac
	if [[ "$last_fail" =~ ^[0-9]+$ ]] && [[ "$neg_age" -ge 0 ]] && [[ "$neg_age" -lt "$active_ttl" ]]; then
		print_warning "Canary negative cache active (age=${neg_age}s, ttl=${active_ttl}s, reason=${fail_reason}) — failing fast (t2814/t2887/t3210)"
		return 0
	fi
	return 1
}

_resolve_canary_opencode_binary() {
	local fail_cache_file="$1"
	local fail_reason_file="$2"
	_CANARY_EFFECTIVE_OPENCODE_BIN="${HEADLESS_OPENCODE_BIN:-$OPENCODE_BIN_DEFAULT}"
	local validate_rc=0
	_validate_opencode_binary "$_CANARY_EFFECTIVE_OPENCODE_BIN" || validate_rc=$?
	if [[ "$validate_rc" -eq 0 ]]; then
		return 0
	fi

	# GH#21003: reuse the version captured by binary validation.
	local wrong_version="${_VALIDATE_OC_VERSION:-<missing>}"
	local alt_bin=""
	if alt_bin=$(_find_alternative_opencode_binary); then
		print_warning "Canary: headless OpenCode binary='${_CANARY_EFFECTIVE_OPENCODE_BIN}' is invalid (version='${wrong_version}', rc=${validate_rc}) — falling back to '${alt_bin}' (t2887)"
		_CANARY_EFFECTIVE_OPENCODE_BIN="$alt_bin"
		export OPENCODE_BIN="$alt_bin"
		return 0
	fi

	# Structural failure: stamp config_error so later attempts fail fast.
	print_warning "Canary: headless OpenCode binary='${_CANARY_EFFECTIVE_OPENCODE_BIN}' returns '${wrong_version}' (rc=${validate_rc}) — not anomalyco/opencode."
	print_warning "Canary: searched $(_opencode_fixed_candidate_dirs_for_warning) — no valid binary found."
	print_warning "Canary: install with 'npm install -g opencode-ai' or set OPENCODE_BIN to a valid binary (t2887)."
	mkdir -p "${STATE_DIR}" 2>/dev/null || true
	date +%s >"$fail_cache_file" 2>/dev/null || true
	printf 'config_error\n' >"$fail_reason_file" 2>/dev/null || true
	return 1
}

_select_canary_model() {
	local canary_model="$1"
	if [[ -z "$canary_model" ]]; then
		while IFS= read -r canary_model; do
			[[ -n "$canary_model" ]] && break
		done < <(get_configured_models)
	fi
	if [[ -z "$canary_model" ]]; then
		canary_model="$DEFAULT_HEADLESS_MODELS"
	fi
	printf '%s' "$canary_model"
	return 0
}

_prepare_canary_isolation() {
	local canary_model="$1"
	# A fresh DB avoids opening a large shared opencode.db during the probe.
	local _canary_data_dir=""
	_canary_data_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-canary-db.XXXXXX")
	mkdir -p "${_canary_data_dir}/opencode"
	# Isolated config avoids stale global default_agent validation. Include the
	# aidevops plugin when present so OAuth follows the worker auth path.
	local _canary_config_dir=""
	_canary_config_dir=$(mktemp -d "${TMPDIR:-/tmp}/aidevops-canary-config.XXXXXX")
	mkdir -p "${_canary_config_dir}/opencode"
	local _canary_plugin_path
	_canary_plugin_path="${AIDEVOPS_PLUGIN_INDEX:-${HOME}/.aidevops/agents/plugins/opencode-aidevops/index.mjs}"
	local _canary_plugin_url=""
	if [[ -f "$_canary_plugin_path" ]]; then
		_canary_plugin_url=$(python3 -c 'import pathlib, sys; print(pathlib.Path(sys.argv[1]).absolute().as_uri())' "$_canary_plugin_path" 2>/dev/null || printf 'file://%s' "$_canary_plugin_path")
	fi
	jq -n --arg plugin_url "$_canary_plugin_url" \
		'{"$schema":"https://opencode.ai/config.json"} + (if $plugin_url == "" then {} else {plugin: [$plugin_url]} end)' \
		>"${_canary_config_dir}/opencode/opencode.json"

	local _canary_default_provider="anthropic"
	local _canary_provider
	_canary_provider=$(extract_provider "$canary_model" 2>/dev/null || printf '%s' "$_canary_default_provider")
	[[ -n "$_canary_provider" ]] || _canary_provider="$_canary_default_provider"
	local _oc_auth="${XDG_DATA_HOME:-$HOME/.local/share}/opencode/auth.json"
	if [[ -f "$_oc_auth" ]]; then
		copy_scoped_opencode_auth "$_oc_auth" "${_canary_data_dir}/opencode/auth.json" "$_canary_provider"
	fi
	# Mirror worker OAuth rotation before invoking OpenCode (t3362).
	if [[ -f "${_canary_data_dir}/opencode/auth.json" ]] && declare -F _maybe_rotate_isolated_auth >/dev/null 2>&1; then
		XDG_DATA_HOME="$_canary_data_dir" _maybe_rotate_isolated_auth \
			"${_canary_data_dir}/opencode/auth.json" "$_canary_provider" || true
	fi

	_CANARY_DATA_DIR="$_canary_data_dir"
	_CANARY_CONFIG_DIR="$_canary_config_dir"
	return 0
}

_execute_canary_probe() {
	local _effective_opencode_bin="$1"
	local canary_model="$2"
	local canary_output="$3"
	local _canary_config_dir="$4"
	local _canary_data_dir="$5"
	local canary_attach_args=()
	local _canary_server_info=""
	if _canary_server_info=$(_detect_opencode_server); then
		local _canary_url
		local _canary_pass
		_canary_url=$(echo "$_canary_server_info" | head -1)
		_canary_pass=$(echo "$_canary_server_info" | tail -1)
		canary_attach_args=(--attach "$_canary_url" --password "$_canary_pass")
	fi

	# Prefer process-group-aware coreutils timeout; perl is the last resort.
	local _canary_timeout_cmd=()
	if command -v timeout >/dev/null 2>&1; then
		_canary_timeout_cmd=(timeout --kill-after=5s "${CANARY_TIMEOUT_SECONDS}s")
	elif command -v gtimeout >/dev/null 2>&1; then
		_canary_timeout_cmd=(gtimeout --kill-after=5s "${CANARY_TIMEOUT_SECONDS}s")
	else
		_canary_timeout_cmd=(perl -e "alarm $CANARY_TIMEOUT_SECONDS; exec @ARGV" --)
	fi

	_CANARY_PROBE_EXIT=0
	XDG_CONFIG_HOME="$_canary_config_dir" XDG_DATA_HOME="$_canary_data_dir" \
		AIDEVOPS_HEADLESS=1 \
		run_without_opencode_session_env "${_canary_timeout_cmd[@]}" \
		"$_effective_opencode_bin" run "What is two plus two? Answer with the single word: Four" \
		-m "$canary_model" --dir "${HOME}" --agent build \
		${canary_attach_args[@]+"${canary_attach_args[@]}"} \
		>"$canary_output" 2>&1 || _CANARY_PROBE_EXIT=$?
	return 0
}

_cleanup_canary_isolation() {
	local canary_data_dir="$1"
	local canary_config_dir="$2"
	rm -rf "$canary_data_dir" 2>/dev/null || true
	rm -rf "$canary_config_dir" 2>/dev/null || true
	return 0
}

_canary_output_is_success() {
	local canary_output="$1"
	local cache_file="$2"
	local fail_cache_file="$3"
	local fail_reason_file="$4"
	if ! grep -qwi 'four' "$canary_output"; then
		return 1
	fi
	mkdir -p "${STATE_DIR}" 2>/dev/null || true
	date +%s >"$cache_file"
	rm -f "$fail_cache_file" 2>/dev/null || true
	rm -f "$fail_reason_file" 2>/dev/null || true
	rm -f "$canary_output"
	return 0
}

_record_canary_failure() {
	local canary_output="$1"
	local canary_exit="$2"
	local canary_model="$3"
	local fail_cache_file="$4"
	local fail_reason_file="$5"
	local oc_version="${_VALIDATE_OC_VERSION:-unknown}"
	print_warning "Canary test FAILED (exit=$canary_exit, model=$canary_model, opencode=$oc_version, timeout=${CANARY_TIMEOUT_SECONDS}s)"
	print_warning "Output (last 20 lines): $(tail -20 "$canary_output" 2>/dev/null || echo '<empty>')"
	local canary_reason
	canary_reason=$(_classify_canary_failure_reason "$canary_output" "$canary_exit")
	mkdir -p "${STATE_DIR}" 2>/dev/null || true
	date +%s >"$fail_cache_file" 2>/dev/null || true
	printf '%s\n' "$canary_reason" >"$fail_reason_file" 2>/dev/null || true
	_record_canary_provider_backoff "$canary_model" "$canary_reason" "$canary_output"
	rm -f "$canary_output"
	return 0
}

_run_canary_test() {
	local requested_model="${1:-}"
	local cache_file="${STATE_DIR}/canary-last-pass"
	local fail_cache_file="${STATE_DIR}/canary-last-fail"
	local fail_reason_file="${fail_cache_file}.reason"
	if _canary_pass_cache_is_fresh "$cache_file"; then
		return 0
	fi
	# t2814/t2887: fail fast while the reason-aware negative cache is active.
	if _canary_negative_cache_is_active "$fail_cache_file" "$fail_reason_file"; then
		return 1
	fi

	# t3558: no CPU/load/saturation preflight or sampling. This tests only
	# OpenCode/runtime/model health; other resource gates live elsewhere.
	if ! _resolve_canary_opencode_binary "$fail_cache_file" "$fail_reason_file"; then
		unset _CANARY_EFFECTIVE_OPENCODE_BIN
		return 1
	fi
	local _effective_opencode_bin="$_CANARY_EFFECTIVE_OPENCODE_BIN"
	unset _CANARY_EFFECTIVE_OPENCODE_BIN

	local canary_output
	canary_output=$(mktemp "${TMPDIR:-/tmp}/aidevops-canary.XXXXXX")
	local canary_model
	canary_model=$(_select_canary_model "$requested_model")
	_prepare_canary_isolation "$canary_model"
	local _canary_data_dir="$_CANARY_DATA_DIR"
	local _canary_config_dir="$_CANARY_CONFIG_DIR"
	unset _CANARY_DATA_DIR _CANARY_CONFIG_DIR

	_execute_canary_probe "$_effective_opencode_bin" "$canary_model" "$canary_output" \
		"$_canary_config_dir" "$_canary_data_dir"
	local canary_exit="${_CANARY_PROBE_EXIT:-1}"
	unset _CANARY_PROBE_EXIT
	_cleanup_canary_isolation "$_canary_data_dir" "$_canary_config_dir"
	if _canary_output_is_success "$canary_output" "$cache_file" "$fail_cache_file" "$fail_reason_file"; then
		return 0
	fi

	_record_canary_failure "$canary_output" "$canary_exit" "$canary_model" \
		"$fail_cache_file" "$fail_reason_file"
	return 1
}

# --- Sub-library sourcing (GH#19699) ---
# Model choice + cmd builders (Sections 13-14)
# shellcheck source=./headless-runtime-model.sh
# shellcheck disable=SC1091  # sub-library resolved at runtime via $SCRIPT_DIR
source "${SCRIPT_DIR}/headless-runtime-model.sh"
