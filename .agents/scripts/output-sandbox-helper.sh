#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# output-sandbox-helper.sh - SQLite-backed raw-output store with compact summaries

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
# shellcheck source=shared-constants.sh
source "${SCRIPT_DIR}/shared-constants.sh"

LOG_PREFIX="OUTPUT-SANDBOX"

SANDBOX_ROOT="${AIDEVOPS_OUTPUT_SANDBOX_DIR:-${HOME}/.aidevops/.agent-workspace/output-sandbox}"
SANDBOX_DB="${AIDEVOPS_OUTPUT_SANDBOX_DB:-${SANDBOX_ROOT}/output-sandbox.db}"
RAW_DIR="${AIDEVOPS_OUTPUT_SANDBOX_RAW_DIR:-${SANDBOX_ROOT}/raw}"
DEFAULT_SUMMARY_LINES="${AIDEVOPS_OUTPUT_SANDBOX_SUMMARY_LINES:-20}"
DEFAULT_DIAGNOSTIC_LINES="${AIDEVOPS_OUTPUT_SANDBOX_DIAGNOSTIC_LINES:-20}"
DEFAULT_RETENTION_DAYS="${AIDEVOPS_OUTPUT_SANDBOX_RETENTION_DAYS:-14}"
DEFAULT_COMPACT_BYTES="${AIDEVOPS_OUTPUT_SANDBOX_COMPACT_BYTES:-8192}"
DEFAULT_COMPACT_LINES="${AIDEVOPS_OUTPUT_SANDBOX_COMPACT_LINES:-80}"

usage() {
	cat <<'EOF'
Usage:
  output-sandbox-helper.sh init
  output-sandbox-helper.sh run [options] -- COMMAND [ARGS...]
  output-sandbox-helper.sh store [--command TEXT] [--exit-code N] [--tag TAG] < output.txt
  output-sandbox-helper.sh show OUTPUT_ID [--offset N] [--limit N]
  output-sandbox-helper.sh cleanup [--max-age-days N]
  output-sandbox-helper.sh stats

Stores noisy command output outside assistant context and returns a compact,
auditable pointer. Exact/verbatim/security-sensitive commands are bypassed.

Run options:
  --tag TAG                    Evidence category (default: run)
  --success-mode MODE          auto|receipt|summary|full (default: auto)
  --failure-mode MODE          diagnostic|summary|full (default: diagnostic)
  --summary-lines N            Maximum summary lines (default: 20)
  --diagnostic-lines N         Maximum failure diagnostic lines (default: 20)
  --expect-text TEXT           Fail when successful output lacks literal TEXT
  --format FORMAT              text|json (default: text)
EOF
	return 0
}

ensure_dirs() {
	if ! mkdir -p "$RAW_DIR"; then
		return 1
	fi
	chmod 700 "$SANDBOX_ROOT" "$RAW_DIR" 2>/dev/null || true
	return 0
}

init_db() {
	ensure_dirs || return 1
	if ! python3 - "$SANDBOX_DB" <<'PY'
import sqlite3, sys
db_path = sys.argv[1]
conn = sqlite3.connect(db_path)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA busy_timeout=5000")
conn.execute("""
CREATE TABLE IF NOT EXISTS outputs (
  id TEXT PRIMARY KEY,
  created_at TEXT NOT NULL,
  command TEXT NOT NULL,
  cwd TEXT NOT NULL,
  repo TEXT NOT NULL,
  exit_code INTEGER NOT NULL,
  tag TEXT NOT NULL,
  raw_path TEXT NOT NULL,
  byte_count INTEGER NOT NULL,
  line_count INTEGER NOT NULL,
  sensitive INTEGER NOT NULL DEFAULT 0,
  summary TEXT NOT NULL
)
""")
conn.execute("CREATE INDEX IF NOT EXISTS idx_outputs_created_at ON outputs(created_at)")
conn.execute("CREATE INDEX IF NOT EXISTS idx_outputs_tag ON outputs(tag)")
conn.commit()
conn.close()
PY
	then
		return 1
	fi
	chmod 600 "$SANDBOX_DB" 2>/dev/null || true
	return 0
}

repo_slug() {
	local cwd="$1"
	git -C "$cwd" remote get-url origin 2>/dev/null |
		sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\.git$##' || true
	return 0
}

make_output_id() {
	python3 - <<'PY'
import secrets, time
print(f"out_{int(time.time())}_{secrets.token_hex(4)}")
PY
	return 0
}

looks_sensitive_file() {
	local path="$1"
	if grep -Eiq '(BEGIN ((RSA|DSA|EC|OPENSSH) )?PRIVATE KEY|aws_secret_access_key|api[_-]?key[=:][[:space:]]*[A-Za-z0-9_./+=-]{20,}|token[=:][[:space:]]*[A-Za-z0-9_./+=-]{24,}|password[=:][^[:space:]]{8,}|gh[pousr]_[A-Za-z0-9_]{20,})' "$path" 2>/dev/null; then
		return 0
	fi
	return 1
}

redact_file() {
	local src="$1"
	local dest="$2"
	python3 - "$src" "$dest" <<'PY'
import re, sys
src, dest = sys.argv[1], sys.argv[2]
data = open(src, 'r', encoding='utf-8', errors='replace').read()
patterns = [
    r'-----BEGIN [A-Z ]*PRIVATE KEY-----.*?-----END [A-Z ]*PRIVATE KEY-----',
    r'(?i)(aws_secret_access_key\s*[=:]\s*)\S+',
    r'(?i)((?:api[_-]?key|token|password)\s*[=:]\s*)\S+',
    r'gh[pousr]_[A-Za-z0-9_]{20,}',
]
for pat in patterns:
    data = re.sub(pat, lambda m: (m.group(1) if m.groups() else '') + '[REDACTED]', data, flags=re.S)
open(dest, 'w', encoding='utf-8').write(data)
PY
	return 0
}

summarize_file() {
	local path="$1"
	local max_lines="$2"
	local sensitive="$3"
	if [[ "$sensitive" == "1" ]]; then
		printf 'summary suppressed: sensitive patterns were redacted before storage\n'
		return 0
	fi
	python3 - "$path" "$max_lines" <<'PY'
import sys
path = sys.argv[1]
limit = int(sys.argv[2])
with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    lines = fh.read().splitlines()
if len(lines) <= limit:
    print('\n'.join(lines))
else:
    head = max(1, limit // 2)
    tail = max(1, limit - head)
    kept = lines[:head] + [f"... omitted {len(lines) - head - tail} line(s); use show for exact output ..."] + lines[-tail:]
    print('\n'.join(kept))
PY
	return 0
}

diagnose_file() {
	local path="$1"
	local max_lines="$2"
	local sensitive="$3"
	if [[ "$sensitive" == "1" ]]; then
		printf 'diagnostic suppressed: sensitive patterns were redacted before storage\n'
		return 0
	fi
	python3 - "$path" "$max_lines" <<'PY'
import re, sys
path, limit = sys.argv[1], int(sys.argv[2])
with open(path, 'r', encoding='utf-8', errors='replace') as fh:
    lines = fh.read().splitlines()
pattern = re.compile(r'(?i)(error|failed|failure|fatal|exception|denied|timeout|timed out|not found|missing)')
selected = []
seen = set()
for index, line in enumerate(lines, start=1):
    if pattern.search(line):
        item = (index, line)
        if item not in seen:
            selected.append(item)
            seen.add(item)
for index, line in list(enumerate(lines, start=1))[-max(3, limit // 2):]:
    item = (index, line)
    if item not in seen:
        selected.append(item)
        seen.add(item)
selected = selected[:limit]
if not selected:
    print('no textual diagnostic lines captured')
else:
    for index, line in selected:
        print(f'{index}: {line}')
PY
	return 0
}

combine_streams() {
	local stdout_path="$1"
	local stderr_path="$2"
	local raw_path="$3"
	python3 - "$stdout_path" "$stderr_path" "$raw_path" <<'PY'
import sys
stdout_path, stderr_path, raw_path = sys.argv[1:]
with open(raw_path, 'wb') as dest:
    for path in (stdout_path, stderr_path):
        with open(path, 'rb') as src:
            data = src.read()
        dest.write(data)
        if data and not data.endswith(b'\n'):
            dest.write(b'\n')
PY
	return 0
}

emit_native_capture() {
	local stdout_path="$1"
	local stderr_path="$2"
	python3 - "$stdout_path" "$stderr_path" <<'PY'
import sys
stdout_path, stderr_path = sys.argv[1:]
for path, destination in ((stdout_path, sys.stdout.buffer), (stderr_path, sys.stderr.buffer)):
    try:
        with open(path, 'rb') as source:
            destination.write(source.read())
            destination.flush()
    except OSError:
        pass
PY
	return 0
}

redact_capture_files() {
	local raw_path="$1"
	local stdout_path="$2"
	local stderr_path="$3"
	local path=""
	for path in "$raw_path" "$stdout_path" "$stderr_path"; do
		local redacted_path="${path}.redacted"
		redact_file "$path" "$redacted_path" || return 1
		mv "$redacted_path" "$path" || return 1
	done
	return 0
}

validate_mode() {
	local mode="$1"
	case "$mode" in
	auto | receipt | summary | diagnostic | full) return 0 ;;
	*) return 1 ;;
	esac
}

validate_positive_integer() {
	local value="$1"
	[[ "$value" =~ ^[1-9][0-9]*$ ]]
	return $?
}

record_output() {
	local output_id="$1"
	local command_text="$2"
	local cwd="$3"
	local exit_code="$4"
	local tag="$5"
	local raw_path="$6"
	local byte_count="$7"
	local line_count="$8"
	local sensitive="$9"
	local summary_file="${10}"
	local repo
	if [[ "${AIDEVOPS_OUTPUT_SANDBOX_TEST_RECORD_FAIL:-0}" == "1" ]]; then
		return 1
	fi
	repo=$(repo_slug "$cwd")
	python3 - "$SANDBOX_DB" "$output_id" "$command_text" "$cwd" "$repo" "$exit_code" "$tag" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file" <<'PY'
import sqlite3, sys
db, oid, command, cwd, repo, exit_code, tag, raw_path, byte_count, line_count, sensitive, summary_file = sys.argv[1:]
summary = open(summary_file, 'r', encoding='utf-8', errors='replace').read()
conn = sqlite3.connect(db)
conn.execute("PRAGMA journal_mode=WAL")
conn.execute("PRAGMA busy_timeout=5000")
conn.execute("""
INSERT OR REPLACE INTO outputs
(id, created_at, command, cwd, repo, exit_code, tag, raw_path, byte_count, line_count, sensitive, summary)
VALUES (?, datetime('now'), ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
""", (oid, command, cwd, repo, int(exit_code), tag, raw_path, int(byte_count), int(line_count), int(sensitive), summary))
conn.commit()
conn.close()
PY
	return 0
}

should_bypass_command() {
	local command_text="$1"
	case "$command_text" in
	cat\ * | head\ * | tail\ * | less\ * | more\ * | git\ diff* | *" --json"* | *" security "* | *secret* | *credential*)
		return 0
		;;
	esac
	return 1
}

print_receipt_text() {
	local output_id="$1"
	local outcome="$2"
	local exit_code="$3"
	local process_exit="$4"
	local byte_count="$5"
	local line_count="$6"
	local sensitive="$7"
	local basis="$8"
	printf 'output_id: %s\n' "$output_id"
	printf 'outcome: %s\n' "$outcome"
	printf 'exit_code: %s\n' "$exit_code"
	printf 'process_exit: %s\n' "$process_exit"
	printf 'evidence: bytes=%s lines=%s sensitive_redacted=%s basis=%s\n' \
		"$byte_count" "$line_count" "$sensitive" "$basis"
	return 0
}

print_receipt_json() {
	local output_id="$1"
	local outcome="$2"
	local exit_code="$3"
	local process_exit="$4"
	local byte_count="$5"
	local line_count="$6"
	local sensitive="$7"
	local basis="$8"
	python3 - "$output_id" "$outcome" "$exit_code" "$process_exit" "$byte_count" "$line_count" "$sensitive" "$basis" <<'PY'
import json, sys
oid, outcome, exit_code, process_exit, byte_count, line_count, sensitive, basis = sys.argv[1:]
print(json.dumps({
    'schema': 'aidevops.operation-result/v1',
    'output_id': oid,
    'outcome': outcome,
    'exit_code': int(exit_code),
    'process_exit': int(process_exit),
    'basis': basis,
    'evidence': {
        'bytes': int(byte_count),
        'lines': int(line_count),
        'sensitive_redacted': sensitive == '1',
    },
}, separators=(',', ':')))
PY
	return 0
}

print_presentation() {
	local format="$1"
	local mode="$2"
	local output_id="$3"
	local outcome="$4"
	local exit_code="$5"
	local process_exit="$6"
	local byte_count="$7"
	local line_count="$8"
	local sensitive="$9"
	local basis="${10}"
	local raw_path="${11}"
	local summary_file="${12}"
	local diagnostic_file="${13}"
	if [[ "$format" == "json" ]]; then
		print_receipt_json "$output_id" "$outcome" "$exit_code" "$process_exit" "$byte_count" "$line_count" "$sensitive" "$basis"
		return 0
	fi
	print_receipt_text "$output_id" "$outcome" "$exit_code" "$process_exit" "$byte_count" "$line_count" "$sensitive" "$basis"
	case "$mode" in
	summary)
		printf 'summary:\n'
		sed 's/^/  /' "$summary_file"
		;;
	diagnostic)
		printf 'diagnostic:\n'
		sed 's/^/  /' "$diagnostic_file"
		;;
	full)
		printf 'output:\n'
		sed 's/^/  /' "$raw_path"
		;;
	receipt) ;;
	esac
	return 0
}

is_verbose_success() {
	local byte_count="$1"
	local line_count="$2"
	[[ "$byte_count" -ge "$DEFAULT_COMPACT_BYTES" || "$line_count" -ge "$DEFAULT_COMPACT_LINES" ]]
	return $?
}

print_verbose_success_summary() {
	local output_id="$1"
	local command_text="$2"
	local exit_code="$3"
	local duration_seconds="$4"
	local byte_count="$5"
	local line_count="$6"
	local sensitive="$7"
	local raw_path="$8"
	if [[ "$sensitive" == "1" ]]; then
		printf 'command: %s\n' "$command_text"
		printf 'exit_status: %s\n' "$exit_code"
		printf 'duration_seconds: %s\n' "$duration_seconds"
		printf 'output: %s bytes across %s lines; sensitive content redacted\n' "$byte_count" "$line_count"
		printf 'full_log: output-sandbox-helper.sh show %s\n' "$output_id"
		return 0
	fi
	python3 - "$raw_path" "$command_text" "$exit_code" "$duration_seconds" "$byte_count" "$line_count" "$output_id" <<'PY'
import re
import sys

path, command, exit_code, duration, byte_count, line_count, output_id = sys.argv[1:]
with open(path, "r", encoding="utf-8", errors="replace") as handle:
    lines = handle.read().splitlines()
warning_pattern = re.compile(r"(?i)(warning|deprecated|deprecation|lint|compiler)")
warnings = [line for line in lines if warning_pattern.search(line)]
test_patterns = (
    re.compile(r"(?i)\btests?\s*[:=]\s*(.+)$"),
    re.compile(r"(?i)\b(\d+)\s+(?:tests?\s+)?passed\b(?:.*?\b(\d+)\s+failed\b)?"),
    re.compile(r"(?i)^#\s*(pass|fail)\s+(\d+)\b"),
)
test_lines = []
for line in lines:
    if any(pattern.search(line) for pattern in test_patterns):
        test_lines.append(line.strip())

print(f"command: {command}")
print(f"exit_status: {exit_code}")
print(f"duration_seconds: {duration}")
print(f"output: {byte_count} bytes across {line_count} lines")
print(f"warnings: {len(warnings)}")
for line in warnings[:4]:
    print(f"  warning: {line}")
if len(warnings) > 4:
    print(f"  ... {len(warnings) - 4} additional warning line(s) retained")
if test_lines:
    print("test_totals:")
    for line in test_lines[:4]:
        print(f"  {line}")
print(f"full_log: output-sandbox-helper.sh show {output_id}")
PY
	return 0
}

present_run_result() {
	local format="$1"
	local mode="$2"
	local output_id="$3"
	local outcome="$4"
	local exit_code="$5"
	local process_exit="$6"
	local byte_count="$7"
	local line_count="$8"
	local sensitive="$9"
	local basis="${10}"
	local raw_path="${11}"
	local summary_file="${12}"
	local diagnostic_file="${13}"
	local duration_seconds="${14}"
	local command_text="${15}"
	if [[ "$outcome" == "succeeded" && "$mode" == "auto" && "$format" == "text" ]]; then
		if is_verbose_success "$byte_count" "$line_count"; then
			print_verbose_success_summary "$output_id" "$command_text" "$exit_code" "$duration_seconds" \
				"$byte_count" "$line_count" "$sensitive" "$raw_path"
		else
			emit_native_capture "$raw_path.stdout" "$raw_path.stderr"
		fi
		return "$exit_code"
	fi
	[[ "$mode" == "auto" ]] && mode="receipt"
	print_presentation "$format" "$mode" "$output_id" "$outcome" "$exit_code" "$process_exit" \
		"$byte_count" "$line_count" "$sensitive" "$basis" "$raw_path" "$summary_file" "$diagnostic_file"
	return "$exit_code"
}

cmd_store() {
	local command_text="stdin"
	local exit_code="0"
	local tag="manual"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--command) local command_value="$2"; command_text="$command_value"; shift 2 ;;
		--exit-code) local exit_value="$2"; exit_code="$exit_value"; shift 2 ;;
		--tag) local tag_value="$2"; tag="$tag_value"; shift 2 ;;
		*) log_error "Unknown store option: $opt"; return 1 ;;
		esac
	done
	if ! init_db; then
		log_error "Output evidence store unavailable"
		return 1
	fi
	local output_id raw_path tmp_input summary_file byte_count line_count sensitive
	output_id=$(make_output_id)
	raw_path="${RAW_DIR}/${output_id}.txt"
	tmp_input="${raw_path}.tmp"
	summary_file="${raw_path}.summary"
	cat >"$tmp_input"
	sensitive=0
	if looks_sensitive_file "$tmp_input"; then
		sensitive=1
		redact_file "$tmp_input" "$raw_path"
		rm -f "$tmp_input"
	else
		mv "$tmp_input" "$raw_path"
	fi
	byte_count=$(wc -c <"$raw_path" | tr -d ' ')
	line_count=$(wc -l <"$raw_path" | tr -d ' ')
	summarize_file "$raw_path" "$DEFAULT_SUMMARY_LINES" "$sensitive" >"$summary_file"
	record_output "$output_id" "$command_text" "$PWD" "$exit_code" "$tag" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file"
	local outcome="succeeded"
	[[ "$exit_code" -eq 0 ]] || outcome="failed"
	print_receipt_text "$output_id" "$outcome" "$exit_code" "$exit_code" "$byte_count" "$line_count" "$sensitive" "exit-code"
	return 0
}

cmd_run() {
	local tag="run" summary_lines="$DEFAULT_SUMMARY_LINES" diagnostic_lines="$DEFAULT_DIAGNOSTIC_LINES"
	local success_mode="auto" failure_mode="diagnostic"
	local expected_text="" format="text"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--tag) local tag_value="$2"; tag="$tag_value"; shift 2 ;;
		--summary-lines) local summary_value="$2"; summary_lines="$summary_value"; shift 2 ;;
		--diagnostic-lines) local diagnostic_value="$2"; diagnostic_lines="$diagnostic_value"; shift 2 ;;
		--success-mode) local success_value="$2"; success_mode="$success_value"; shift 2 ;;
		--failure-mode) local failure_value="$2"; failure_mode="$failure_value"; shift 2 ;;
		--expect-text) local expected_value="$2"; expected_text="$expected_value"; shift 2 ;;
		--format) local format_value="$2"; format="$format_value"; shift 2 ;;
		--) shift; break ;;
		*) log_error "Unknown run option: $opt"; return 1 ;;
		esac
	done
	if [[ $# -eq 0 ]]; then
		log_error "run requires a command after --"
		return 1
	fi
	if ! validate_positive_integer "$summary_lines" || ! validate_positive_integer "$diagnostic_lines"; then
		log_error "summary and diagnostic line counts must be positive integers"
		return 1
	fi
	if ! validate_mode "$success_mode" || [[ "$success_mode" == "diagnostic" ]]; then
		log_error "Invalid success mode: $success_mode"
		return 1
	fi
	if ! validate_mode "$failure_mode" || [[ "$failure_mode" == "receipt" ]]; then
		log_error "Invalid failure mode: $failure_mode"
		return 1
	fi
	if [[ "$format" != "text" && "$format" != "json" ]]; then
		log_error "Invalid format: $format"
		return 1
	fi
	local command_text="${1##*/}" command_shape="$*"
	if should_bypass_command "$command_shape"; then
		printf 'output_sandbox: bypass exact/verbatim command\n' >&2
		"$@"
		return $?
	fi
	if ! init_db; then
		printf 'output_sandbox: evidence store unavailable; running with native output\n' >&2
		"$@"
		return $?
	fi
	local output_id raw_path stdout_path stderr_path summary_file diagnostic_file
	local process_exit exit_code byte_count line_count sensitive outcome="succeeded" basis mode="$success_mode" start_seconds duration_seconds
	start_seconds=$SECONDS
	output_id=$(make_output_id)
	raw_path="${RAW_DIR}/${output_id}.txt"
	stdout_path="${raw_path}.stdout"
	stderr_path="${raw_path}.stderr"
	summary_file="${raw_path}.summary"
	diagnostic_file="${raw_path}.diagnostic"
	set +e
	"$@" >"$stdout_path" 2>"$stderr_path"
	process_exit=$?
	set -e
	if ! combine_streams "$stdout_path" "$stderr_path" "$raw_path"; then
		printf 'output_sandbox: evidence capture failed; returning native output\n' >&2
		emit_native_capture "$stdout_path" "$stderr_path"
		return "$process_exit"
	fi
	exit_code="$process_exit"
	basis="exit-code"
	if [[ "$process_exit" -eq 0 && -n "$expected_text" ]] && ! grep -Fq -- "$expected_text" "$raw_path"; then
		exit_code=1
		basis="missing-expected-text"
	fi
	sensitive=0
	if looks_sensitive_file "$raw_path"; then
		sensitive=1
		if ! redact_capture_files "$raw_path" "$stdout_path" "$stderr_path"; then
			printf 'output_sandbox: evidence redaction failed; captured output suppressed\n' >&2
			return "$exit_code"
		fi
	fi
	byte_count=$(wc -c <"$raw_path" | tr -d ' ')
	line_count=$(wc -l <"$raw_path" | tr -d ' ')
	duration_seconds=$((SECONDS - start_seconds))
	if ! summarize_file "$raw_path" "$summary_lines" "$sensitive" >"$summary_file" || \
		! diagnose_file "$raw_path" "$diagnostic_lines" "$sensitive" >"$diagnostic_file" || \
		! record_output "$output_id" "$command_text" "$PWD" "$exit_code" "$tag" "$raw_path" "$byte_count" "$line_count" "$sensitive" "$summary_file"; then
		printf 'output_sandbox: evidence finalization failed; returning native output\n' >&2
		emit_native_capture "$stdout_path" "$stderr_path"
		return "$exit_code"
	fi
	if [[ "$exit_code" -ne 0 ]]; then
		outcome="failed"
		mode="$failure_mode"
	fi
	present_run_result "$format" "$mode" "$output_id" "$outcome" "$exit_code" "$process_exit" \
		"$byte_count" "$line_count" "$sensitive" "$basis" "$raw_path" "$summary_file" "$diagnostic_file" \
		"$duration_seconds" "$command_text" || return $?
	return "$exit_code"
}

cmd_show() {
	local output_id="$1"
	shift || true
	local offset="1"
	local limit="120"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--offset) local offset_value="$2"; offset="$offset_value"; shift 2 ;;
		--limit) local limit_value="$2"; limit="$limit_value"; shift 2 ;;
		*) log_error "Unknown show option: $opt"; return 1 ;;
		esac
	done
	init_db
	python3 - "$SANDBOX_DB" "$output_id" "$offset" "$limit" <<'PY'
import sqlite3, sys
db, oid, offset, limit = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
conn = sqlite3.connect(db)
row = conn.execute("SELECT raw_path, sensitive FROM outputs WHERE id = ?", (oid,)).fetchone()
conn.close()
if not row:
    print(f"output not found: {oid}", file=sys.stderr)
    sys.exit(1)
raw_path, sensitive = row
if sensitive:
    print("output was redacted before storage; showing redacted raw output", file=sys.stderr)
with open(raw_path, 'r', encoding='utf-8', errors='replace') as fh:
    lines = fh.read().splitlines()
start = max(0, offset - 1)
for number, line in enumerate(lines[start:start + limit], start=start + 1):
    print(f"{number}: {line}")
PY
	return 0
}

cmd_cleanup() {
	local max_age_days="$DEFAULT_RETENTION_DAYS"
	while [[ $# -gt 0 ]]; do
		local opt="$1"
		case "$opt" in
		--max-age-days) local days_value="$2"; max_age_days="$days_value"; shift 2 ;;
		*) log_error "Unknown cleanup option: $opt"; return 1 ;;
		esac
	done
	init_db
	python3 - "$SANDBOX_DB" "$max_age_days" <<'PY'
import os, sqlite3, sys
db, days = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db)
rows = conn.execute("SELECT id, raw_path FROM outputs WHERE created_at < datetime('now', ?)", (f'-{days} days',)).fetchall()
for oid, raw_path in rows:
    for path in (raw_path, raw_path + '.stdout', raw_path + '.stderr', raw_path + '.summary', raw_path + '.diagnostic'):
        try:
            os.remove(path)
        except FileNotFoundError:
            pass
conn.executemany("DELETE FROM outputs WHERE id = ?", [(oid,) for oid, _ in rows])
conn.commit()
conn.execute('VACUUM')
conn.close()
print(f"deleted: {len(rows)}")
PY
	return 0
}

cmd_stats() {
	init_db
	python3 - "$SANDBOX_DB" <<'PY'
import os, sqlite3, sys
db = sys.argv[1]
conn = sqlite3.connect(db)
count, bytes_total = conn.execute('SELECT COUNT(*), COALESCE(SUM(byte_count), 0) FROM outputs').fetchone()
sensitive = conn.execute('SELECT COUNT(*) FROM outputs WHERE sensitive = 1').fetchone()[0]
conn.close()
print(f"outputs: {count}")
print(f"raw_bytes: {bytes_total}")
print(f"sensitive_redacted: {sensitive}")
print(f"db_path: {db}")
print(f"db_bytes: {os.path.getsize(db) if os.path.exists(db) else 0}")
PY
	return 0
}

main() {
	local command="${1:-help}"
	shift || true
	case "$command" in
	init) init_db ;;
	run) cmd_run "$@" ;;
	store) cmd_store "$@" ;;
	show) [[ $# -ge 1 ]] || { log_error "show requires OUTPUT_ID"; return 1; }; cmd_show "$@" ;;
	cleanup) cmd_cleanup "$@" ;;
	stats) cmd_stats ;;
	help | --help | -h) usage ;;
	*) log_error "Unknown command: $command"; usage; return 1 ;;
	esac
	return $?
}

main "$@"
