#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
# session-miner-pulse.sh — Daily self-improvement pulse
#
# Extracts learning signals from coding assistant session data,
# compresses them, and logs TODO suggestions for harness improvements.
#
# Designed for OpenCode now, adaptable to Claude Code or other tools.
#
# Usage:
#   session-miner-pulse.sh                    # Run with defaults
#   session-miner-pulse.sh --since 24h        # Only sessions from last 24h
#   session-miner-pulse.sh --db /path/to.db   # Custom DB path
#   session-miner-pulse.sh --dry-run          # Show what would be logged, don't write
#
# Called by: supervisor pulse (daily), manual invocation
# Output: Suggestions written to stdout. Use with opencode run for analysis.

set -euo pipefail

# --- Configuration ---

_smp_dir="${BASH_SOURCE[0]%/*}"
[[ "$_smp_dir" == "${BASH_SOURCE[0]}" ]] && _smp_dir="."
SCRIPT_DIR="$(cd "$_smp_dir" && pwd)"

# Source shared-constants.sh for portable stat functions
# shellcheck source=shared-constants.sh
[[ -f "${SCRIPT_DIR}/shared-constants.sh" ]] && source "${SCRIPT_DIR}/shared-constants.sh"
MINER_DIR="${HOME}/.aidevops/.agent-workspace/work/session-miner"
# Shipped with aidevops; copied to workspace on first run
EXTRACTOR_SRC="${SCRIPT_DIR}/session-miner/extract.py"
COMPRESSOR_SRC="${SCRIPT_DIR}/session-miner/compress.py"
EXTRACTOR="${MINER_DIR}/extract.py"
COMPRESSOR="${MINER_DIR}/compress.py"
STATE_FILE="${MINER_DIR}/.last-pulse"
LOCK_FILE="${MINER_DIR}/.pulse.lock"

# Default: OpenCode DB
DEFAULT_DB="${HOME}/.local/share/opencode/opencode.db"

# Minimum interval between pulses (seconds) — default 20 hours
MIN_INTERVAL="${SESSION_MINER_INTERVAL:-72000}"

# --- Functions ---

log_info() {
	local msg="$1"
	echo "[session-miner] ${msg}" >&2
	return 0
}

log_error() {
	local msg="$1"
	echo "[session-miner] ERROR: ${msg}" >&2
	return 0
}

check_lock() {
	if [[ -f "${LOCK_FILE}" ]]; then
		local lock_age
		local lock_mtime
		lock_mtime=$(_file_mtime_epoch "${LOCK_FILE}")
		lock_age=$(($(date +%s) - lock_mtime))
		# Stale lock (>1 hour)
		if [[ "${lock_age}" -gt 3600 ]]; then
			log_info "Removing stale lock (${lock_age}s old)"
			rm -f "${LOCK_FILE}"
		else
			log_info "Another pulse is running (lock age: ${lock_age}s). Exiting."
			return 1
		fi
	fi
	echo "$$" >"${LOCK_FILE}"
	return 0
}

release_lock() {
	rm -f "${LOCK_FILE}"
	return 0
}

check_interval() {
	if [[ -f "${STATE_FILE}" ]]; then
		local last_run
		last_run=$(cat "${STATE_FILE}" 2>/dev/null || echo 0)
		local now
		now=$(date +%s)
		local elapsed=$((now - last_run))
		if [[ "${elapsed}" -lt "${MIN_INTERVAL}" ]]; then
			local remaining=$((MIN_INTERVAL - elapsed))
			log_info "Last pulse was ${elapsed}s ago. Next in ${remaining}s. Skipping."
			return 1
		fi
	fi
	return 0
}

record_pulse() {
	mkdir -p "${MINER_DIR}"
	date +%s >"${STATE_FILE}"
	return 0
}

detect_db() {
	local db_path="$1"

	if [[ -n "${db_path}" ]] && [[ -f "${db_path}" ]]; then
		echo "${db_path}"
		return 0
	fi

	# OpenCode
	if [[ -f "${DEFAULT_DB}" ]]; then
		echo "${DEFAULT_DB}"
		return 0
	fi

	# Claude Code (future — placeholder)
	# local claude_db="${HOME}/.claude/sessions.db"
	# if [[ -f "${claude_db}" ]]; then
	#     echo "${claude_db}"
	#     return 0
	# fi

	log_error "No session database found"
	return 1
}

count_new_sessions() {
	local db_path="$1"
	local since_ts="$2"

	local count
	count=$(sqlite3 "${db_path}" "SELECT COUNT(*) FROM session WHERE time_created > ${since_ts};" 2>/dev/null || echo 0)
	echo "${count}"
	return 0
}

run_extraction() {
	local db_path="$1"
	local output_dir="$2"

	if [[ ! -f "${EXTRACTOR}" ]]; then
		log_error "Extractor not found at ${EXTRACTOR}"
		return 1
	fi

	log_info "Running extraction from ${db_path}..."
	python3 "${EXTRACTOR}" --db "${db_path}" --format chunks --output "${output_dir}" 2>&1
	return $?
}

run_compression() {
	local chunks_dir="$1"

	if [[ ! -f "${COMPRESSOR}" ]]; then
		log_error "Compressor not found at ${COMPRESSOR}"
		return 1
	fi

	log_info "Running compression..."
	python3 "${COMPRESSOR}" "${chunks_dir}" 2>&1
	return $?
}

run_repo_scoped_extraction() {
	local db_path="$1"
	local output_dir="$2"
	local repo_dir="$3"

	if [[ ! -f "${EXTRACTOR}" ]]; then
		log_error "Extractor not found at ${EXTRACTOR}"
		return 1
	fi

	log_info "Running repo-scoped extraction from ${db_path} for ${repo_dir}..."
	python3 "${EXTRACTOR}" --db "${db_path}" --format chunks --output "${output_dir}" --repo-dir "${repo_dir}" 2>&1
	return $?
}

run_repo_scoped_pipeline() {
	local db_path="$1"
	local repo_dir="$2"
	local slug="$3"

	local slug_safe
	slug_safe="${slug//\//_}"
	local scoped_output_dir="${_output_dir}/contributor_${slug_safe}"
	mkdir -p "${scoped_output_dir}"

	local extract_output
	extract_output=$(run_repo_scoped_extraction "${db_path}" "${scoped_output_dir}" "${repo_dir}" 2>&1) || {
		log_error "Repo-scoped extraction failed for ${slug}: ${extract_output}"
		return 1
	}

	local chunks_dir
	chunks_dir=$(find "${scoped_output_dir}" -maxdepth 1 -type d -name "chunks_*" | head -1)
	if [[ -z "${chunks_dir}" ]]; then
		log_error "No repo-scoped chunks directory found for ${slug} in ${scoped_output_dir}"
		return 1
	fi

	local compression_output
	compression_output=$(run_compression "${chunks_dir}" 2>&1) || {
		log_error "Repo-scoped compression failed for ${slug}: ${compression_output}"
		return 1
	}

	local scoped_compressed_file="${scoped_output_dir}/compressed_signals.json"
	if [[ ! -f "${scoped_compressed_file}" ]]; then
		log_error "Repo-scoped compressed signals file not produced for ${slug}"
		return 1
	fi

	printf '%s\n' "${scoped_compressed_file}"
	return 0
}

# _summary_print_header prints the pulse summary header with steerage and error counts.
_summary_print_header() {
	local compressed_file="$1"
	python3 -c "
import json
from pathlib import Path
data = json.loads(Path('${compressed_file}').read_text())
steerage = data.get('steerage', {})
errors = data.get('errors', {}).get('patterns', [])
total_steerage = sum(len(v) for v in steerage.values())
top_errors = [p for p in errors if p['count'] > 10]
print('## Session Miner Pulse Summary')
print()
print(f'Unique steerage signals: {total_steerage}')
print(f'Error patterns (>10 occurrences): {len(top_errors)}')
print()
" 2>/dev/null
	return $?
}

# _summary_print_error_patterns prints top error patterns and steerage categories,
# plus suggested harness improvements for uncovered high-frequency errors.
_summary_print_error_patterns() {
	local compressed_file="$1"
	python3 -c "
import json
from pathlib import Path
data = json.loads(Path('${compressed_file}').read_text())
steerage = data.get('steerage', {})
errors = data.get('errors', {}).get('patterns', [])
top_errors = [p for p in errors if p['count'] > 10]
top_errors.sort(key=lambda x: -x['count'])
cat_counts = {k: len(v) for k, v in steerage.items()}

if top_errors:
    print('### Top Error Patterns')
    for p in top_errors[:10]:
        recovery = p.get('recovery_patterns', [])
        recovery_str = f' -> recovery: {recovery[0][:60]}' if recovery else ''
        print(f'  {p[\"tool\"]}:{p[\"error_category\"]} ({p[\"count\"]}x){recovery_str}')
    print()

if cat_counts:
    print('### Steerage Categories')
    for cat, count in sorted(cat_counts.items(), key=lambda x: -x[1]):
        print(f'  {cat}: {count}')
    print()

harness_covered = {'edit_stale_read', 'not_read_first', 'edit_mismatch'}
uncovered = [p for p in top_errors if p['error_category'] not in harness_covered]
if uncovered:
    print('### Suggested Harness Improvements')
    for p in uncovered[:5]:
        print(f'  - {p[\"tool\"]}:{p[\"error_category\"]} ({p[\"count\"]}x) — consider adding prevention rule')
    print()
" 2>/dev/null
	return $?
}

# _summary_print_git_productivity prints git correlation and per-project productivity stats.
_summary_print_git_productivity() {
	local compressed_file="$1"
	python3 -c "
import json
from pathlib import Path
data = json.loads(Path('${compressed_file}').read_text())
git_data = data.get('git_correlation', {})
git_summary = git_data.get('summary', {})
if not git_summary:
    raise SystemExit(0)

total_s = git_summary.get('total_sessions', 0)
productive_s = git_summary.get('productive_sessions', 0)
rate = git_summary.get('productivity_rate', 0)
total_commits = git_summary.get('total_commits', 0)
avg_cpm = git_summary.get('avg_commits_per_message', 0)
print('### Git Productivity')
print(f'  Sessions with git data: {total_s}')
print(f'  Productive sessions (>=1 commit): {productive_s} ({rate:.0%})')
print(f'  Total commits: {total_commits}')
print(f'  Avg commits/message (productive): {avg_cpm:.3f}')
print()

project_stats = git_data.get('project_stats', {})
if project_stats:
    print('### Productivity by Project')
    for project, ps in sorted(project_stats.items(), key=lambda x: -x[1].get('total_commits', 0))[:10]:
        print(f'  {project}: {ps[\"productive_sessions\"]}/{ps[\"sessions\"]} productive, '
              f'{ps[\"total_commits\"]} commits, {ps[\"total_lines_changed\"]} lines')
    print()

top_sessions = git_data.get('top_productive_sessions', [])
if top_sessions:
    print('### Most Productive Sessions')
    for s in top_sessions[:5]:
        print(f'  {s[\"title\"][:60]} — {s[\"commits\"]} commits/{s[\"messages\"]} msgs '
              f'(ratio: {s[\"ratio\"]:.2f}, {s[\"duration_min\"]:.0f}min)')
    print()
" 2>/dev/null
	return $?
}

# _summary_print_instruction_candidates prints detected instruction candidates per target file.
_summary_print_instruction_candidates() {
	local compressed_file="$1"
	python3 -c "
import json
import re
from pathlib import Path

REDACTION_PLACEHOLDER = '[REDACTED secret-adjacent instruction candidate]'
SECRET_ADJACENT_PATTERN = re.compile(
    r'\\b(credential(?:s)?|password(?:s)?|token(?:s)?|api\\s*key(?:s)?|secret(?:s)?|'
    r'authorization|bearer|private\\s+key(?:s)?)\\b',
    re.IGNORECASE,
)

def display_text(candidate):
    text = candidate.get('display_text') or candidate.get('text', '')
    if SECRET_ADJACENT_PATTERN.search(text):
        return REDACTION_PLACEHOLDER
    return text

data = json.loads(Path('${compressed_file}').read_text())
instruction_candidates = data.get('instruction_candidates', {})
total_candidates = sum(len(v) for v in instruction_candidates.values())
if total_candidates == 0:
    raise SystemExit(0)

print('### Instruction Candidates')
print(f'  Total: {total_candidates} candidate(s) detected across sessions')
print()
for target_file, candidates in sorted(instruction_candidates.items()):
    if not candidates:
        continue
    print(f'  Target: {target_file} ({len(candidates)} candidate(s))')
    for c in candidates[:5]:
        conf = c.get('confidence', 0)
        cat = c.get('category', 'general')
        text = display_text(c)[:120].replace('\n', ' ')
        session = c.get('session_title', '')[:40]
        print(f'    [{conf:.0%} {cat}] \"{text}\"')
        if session:
            print(f'      (from: {session})')
    if len(candidates) > 5:
        print(f'    ... and {len(candidates) - 5} more')
    print()
" 2>/dev/null
	return $?
}

# generate_summary prints a human-readable pulse summary from a compressed signals file.
# Delegates to focused helpers: header, error patterns, git productivity, instruction candidates.
generate_summary() {
	local compressed_file="$1"

	if [[ ! -f "${compressed_file}" ]]; then
		log_error "Compressed signals file not found"
		return 1
	fi

	_summary_print_header "${compressed_file}" || return 1
	_summary_print_error_patterns "${compressed_file}" || return 1
	_summary_print_git_productivity "${compressed_file}" || true
	_summary_print_instruction_candidates "${compressed_file}" || true
	return 0
}

generate_feedback_actions() {
	local compressed_file="$1"
	local actions_file="$2"
	local report_file="$3"
	local metrics_file="$4"

	if [[ ! -f "${compressed_file}" ]]; then
		log_error "Compressed signals file not found"
		return 1
	fi

	python3 - "${compressed_file}" "${actions_file}" "${report_file}" "${metrics_file}" <<'PY'
import json
import sys
import re
from datetime import datetime, timezone
from pathlib import Path

REDACTION_PLACEHOLDER = "[REDACTED secret-adjacent instruction candidate]"
SECRET_ADJACENT_PATTERN = re.compile(
    r"\b(credential(?:s)?|password(?:s)?|token(?:s)?|api\s*key(?:s)?|secret(?:s)?|"
    r"authorization|bearer|private\s+key(?:s)?)\b",
    re.IGNORECASE,
)


def display_instruction_candidate_text(candidate):
    text = candidate.get("display_text") or candidate.get("text", "")
    if SECRET_ADJACENT_PATTERN.search(text):
        return REDACTION_PLACEHOLDER
    return text

compressed_path = Path(sys.argv[1])
actions_path = Path(sys.argv[2])
report_path = Path(sys.argv[3])
metrics_path = Path(sys.argv[4])

data = json.loads(compressed_path.read_text())
errors = data.get("errors", {}).get("patterns", [])

severity_weights = {
    "high": 4,
    "medium": 2,
    "low": 1,
}

high_impact_categories = {
    "permission",
    "not_read_first",
    "edit_stale_read",
}

def action_kind(pattern):
    count = pattern.get("count", 0)
    model_count = pattern.get("model_count", 0)
    category = pattern.get("error_category", "other")
    severity = pattern.get("severity", "low")

    is_common = count >= 8 or (count >= 4 and model_count >= 2)
    is_outlier = (category in high_impact_categories and count >= 1) or (severity == "high" and model_count >= 1)

    if is_common:
        return "common"
    if is_outlier:
        return "outlier"
    return None


def build_actions(patterns):
    actions = []
    for p in patterns:
        kind = action_kind(p)
        if kind is None:
            continue

        tool = p.get("tool", "unknown")
        category = p.get("error_category", "other")
        count = int(p.get("count", 0))
        models = p.get("models", [])
        model_count = int(p.get("model_count", 0))
        severity = p.get("severity", "low")
        score = (count * severity_weights.get(severity, 1)) + (model_count * 3)

        tag = f"session-miner:{tool}:{category}"
        title = f"session-miner: reduce {tool} {category} failures"
        why = "Cross-model recurring failure pattern" if model_count >= 2 else "High-impact outlier requiring harness hardening"

        body = "\n".join([
            "## Summary",
            f"- Source: session-miner feedback loop ({kind} lane)",
            f"- Pattern: `{tool}:{category}`",
            f"- Frequency: {count}",
            f"- Models affected: {model_count} ({', '.join(models) if models else 'unknown'})",
            f"- Severity: {severity}",
            "",
            "## Why This Matters",
            f"- {why}",
            "- Improvements should remain model-agnostic: fix the harness/process, not a model-specific workaround.",
            "",
            "## Suggested Actions",
            "- Add or tighten preventive guidance in prompts/scripts",
            "- Add/expand validation checks for this error class",
            "- Add regression verification for this failure mode",
            "",
            "## Verification",
            "- Re-run session-miner pulse and compare this pattern's frequency against baseline",
            "",
            f"Signal tag: `{tag}`",
        ])

        actions.append({
            "title": title,
            "tag": tag,
            "kind": kind,
            "tool": tool,
            "error_category": category,
            "count": count,
            "models": models,
            "model_count": model_count,
            "severity": severity,
            "score": score,
            "body": body,
        })

    actions.sort(key=lambda x: (-x["score"], -x["count"], x["title"]))
    return actions


actions = build_actions(errors)

metrics = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "patterns": {
        f"{p.get('tool', 'unknown')}:{p.get('error_category', 'other')}": {
            "count": int(p.get("count", 0)),
            "model_count": int(p.get("model_count", 0)),
            "severity": p.get("severity", "low"),
        }
        for p in errors
    },
}

previous_metrics = {}
if metrics_path.exists():
    try:
        previous_metrics = json.loads(metrics_path.read_text())
    except (OSError, json.JSONDecodeError):
        previous_metrics = {}

previous_patterns = previous_metrics.get("patterns", {})
delta_lines = []
for key, cur in sorted(metrics["patterns"].items()):
    prev_count = int(previous_patterns.get(key, {}).get("count", 0))
    diff = cur["count"] - prev_count
    if diff != 0:
        trend = "increased" if diff > 0 else "decreased"
        delta_lines.append(f"- `{key}` {trend} by {abs(diff)} ({prev_count} -> {cur['count']})")

payload = {
    "generated_at": metrics["generated_at"],
    "total_actions": len(actions),
    "actions": actions,
    "delta": delta_lines,
}

actions_path.write_text(json.dumps(payload, indent=2), encoding="utf-8")
metrics_path.write_text(json.dumps(metrics, indent=2), encoding="utf-8")

lines = [
    "# Session Miner Feedback Actions",
    "",
    f"Generated: {metrics['generated_at']}",
    f"Total candidate actions: {len(actions)}",
    "",
    "## Candidate Actions",
]

if actions:
    for action in actions:
        lines.extend([
            f"- [{action['kind']}] {action['title']}",
            f"  - pattern: `{action['tool']}:{action['error_category']}`",
            f"  - count: {action['count']}, models: {action['model_count']}, severity: {action['severity']}",
            f"  - tag: `{action['tag']}`",
        ])
else:
    lines.append("- No action candidates matched current thresholds")

lines.extend(["", "## Pattern Delta Since Last Pulse"])
if delta_lines:
    lines.extend(delta_lines)
else:
    lines.append("- No count changes detected from previous pulse")

# Instruction candidates section
instruction_candidates = data.get("instruction_candidates", {})
total_candidates = sum(len(v) for v in instruction_candidates.values())
lines.extend(["", "## Instruction Candidates"])
if total_candidates > 0:
    lines.append(f"Total: {total_candidates} candidate(s) detected — review and add to instruction files as appropriate.")
    lines.append("")
    for target_file, candidates in sorted(instruction_candidates.items()):
        if not candidates:
            continue
        lines.append(f"### {target_file} ({len(candidates)} candidate(s))")
        for c in candidates[:10]:
            conf = c.get("confidence", 0)
            cat = c.get("category", "general")
            text = display_instruction_candidate_text(c)[:200].replace("\n", " ")
            session = c.get("session_title", "")[:60]
            lines.append(f"- [{conf:.0%} / {cat}] {text}")
            if session:
                lines.append(f"  _(from session: {session})_")
        if len(candidates) > 10:
            lines.append(f"- ... and {len(candidates) - 10} more (see compressed_signals.json)")
        lines.append("")
else:
    lines.append("- No instruction candidates detected in this pulse")

report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
print(f"Generated {len(actions)} action candidates")
print(f"Actions file: {actions_path}")
print(f"Report file: {report_path}")
print(f"Metrics baseline: {metrics_path}")
PY

	return $?
}

create_feedback_issues() {
	local actions_file="$1"
	local dry_run="$2"
	local auto_issue="${SESSION_MINER_AUTO_ISSUES:-0}"

	if [[ "${auto_issue}" != "1" ]]; then
		log_info "Auto-issue creation disabled (set SESSION_MINER_AUTO_ISSUES=1 to enable)"
		return 0
	fi

	if [[ ! -f "${actions_file}" ]]; then
		log_error "Actions file not found: ${actions_file}"
		return 1
	fi

	if ! command -v gh >/dev/null 2>&1; then
		log_info "gh CLI not found, skipping auto-issue creation"
		return 0
	fi

	local max_issues="${SESSION_MINER_MAX_ISSUES:-3}"
	python3 - "${actions_file}" "${max_issues}" "${dry_run}" <<'PY'
import json
import subprocess
import sys

actions_file = sys.argv[1]
max_issues = int(sys.argv[2])
dry_run = sys.argv[3].lower() == "true"

payload = json.load(open(actions_file, encoding="utf-8"))
actions = payload.get("actions", [])

if not actions:
    print("No action candidates to file")
    sys.exit(0)

repo_cmd = ["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]
repo = subprocess.run(repo_cmd, capture_output=True, text=True)
if repo.returncode != 0:
    print("Unable to resolve repository slug; skipping issue creation")
    sys.exit(0)

slug = repo.stdout.strip()
created = 0

for action in actions:
    if created >= max_issues:
        break

    tag = action["tag"]
    title = action["title"]
    body = action["body"]

    dedup_cmd = [
        "gh", "issue", "list",
        "--repo", slug,
        "--state", "open",
        "--search", f'"{tag}" in:body',
        "--limit", "1",
        "--json", "number",
    ]
    dedup = subprocess.run(dedup_cmd, capture_output=True, text=True)
    if dedup.returncode == 0:
        try:
            existing = json.loads(dedup.stdout)
        except json.JSONDecodeError:
            existing = []
        if existing:
            continue

    if dry_run:
        print(f"DRY RUN: would create issue: {title}")
        created += 1
        continue

    create_cmd = [
        "gh", "issue", "create",
        "--repo", slug,
        "--title", title,
        "--body", body,
        "--label", "self-improvement",
    ]
    created_proc = subprocess.run(create_cmd, capture_output=True, text=True)
    if created_proc.returncode == 0:
        print(f"Created issue: {title}")
        created += 1

print(f"Issue creation complete: {created} created (cap={max_issues})")
PY

	return $?
}

# --- Main helpers ---

# parse_args sets script-level variables: _db_override, _dry_run, _force, _create_issues
parse_args() {
	_db_override=""
	_dry_run=false
	_force=false
	_create_issues=false

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--db)
			_db_override="$2"
			shift 2
			;;
		--dry-run)
			_dry_run=true
			shift
			;;
		--force)
			_force=true
			shift
			;;
		--create-issues)
			_create_issues=true
			shift
			;;
		--since)
			# Ignored for now — full extraction each time, incremental later
			shift 2
			;;
		*)
			log_error "Unknown argument: $1"
			return 1
			;;
		esac
	done
	return 0
}

sync_scripts() {
	mkdir -p "${MINER_DIR}"
	# Copy all Python modules from source to workspace (not just extract.py + compress.py).
	# Resilient to future refactoring: any new .py added to scripts/session-miner/ is
	# automatically deployed. Fixes regression from t1944 which added 5 helper modules
	# (extract_chunking.py, extract_errors.py, extract_git.py, extract_shared.py,
	# extract_steerage.py) without updating this copy logic. Ref: GH#18383.
	local _miner_src_dir="${SCRIPT_DIR}/session-miner"
	local _py_src
	local _py_dst
	for _py_src in "${_miner_src_dir}"/*.py; do
		[[ -f "${_py_src}" ]] || continue
		_py_dst="${MINER_DIR}/$(basename "${_py_src}")"
		if [[ ! -f "${_py_dst}" || "${_py_src}" -nt "${_py_dst}" ]]; then
			cp "${_py_src}" "${_py_dst}"
		fi
	done
	return 0
}

# validate_db_size checks the DB is large enough to mine.
# Prints the db_path on success; returns 1 if too small or not found.
validate_db_size() {
	local db_path="$1"
	local db_size
	db_size=$(_file_size_bytes "${db_path}")
	if [[ "${db_size}" -lt 1000 ]]; then
		log_info "Database too small (${db_size} bytes). Nothing to mine."
		return 1
	fi
	return 0
}

# run_pipeline runs extraction + compression and verifies output.
# Sets _output_dir, _compressed_file, _feedback_actions_file,
# _feedback_report_file, _feedback_metrics_file on success.
run_pipeline() {
	local db_path="$1"

	local run_ts
	run_ts=$(date +%Y%m%d_%H%M%S)
	_output_dir="${MINER_DIR}/pulse_${run_ts}"
	mkdir -p "${_output_dir}"

	local extract_output
	extract_output=$(run_extraction "${db_path}" "${_output_dir}" 2>&1) || {
		log_error "Extraction failed: ${extract_output}"
		return 1
	}

	local chunks_dir
	chunks_dir=$(find "${_output_dir}" -maxdepth 1 -type d -name "chunks_*" | head -1)
	if [[ -z "${chunks_dir}" ]]; then
		log_error "No chunks directory found in ${_output_dir}"
		return 1
	fi

	run_compression "${chunks_dir}" 2>&1 || {
		log_error "Compression failed"
		return 1
	}

	_compressed_file="${_output_dir}/compressed_signals.json"
	_feedback_actions_file="${MINER_DIR}/feedback_actions.json"
	_feedback_report_file="${MINER_DIR}/feedback_actions.md"
	_feedback_metrics_file="${MINER_DIR}/feedback_metrics.json"

	if [[ ! -f "${_compressed_file}" ]]; then
		log_error "Compressed signals file not produced at ${_compressed_file}"
		return 1
	fi
	return 0
}

# output_results prints summary and feedback, optionally creates issues,
# and records the pulse timestamp when not in dry-run mode.
output_results() {
	local dry_run="$1"
	local create_issues="$2"

	local summary
	summary=$(generate_summary "${_compressed_file}" 2>&1)

	local feedback_output
	feedback_output=$(generate_feedback_actions "${_compressed_file}" "${_feedback_actions_file}" "${_feedback_report_file}" "${_feedback_metrics_file}" 2>&1) || {
		log_error "Feedback action generation failed: ${feedback_output}"
		return 1
	}

	if [[ "${dry_run}" == true ]]; then
		echo "--- DRY RUN ---"
		echo "${summary}"
		echo "${feedback_output}"
		if [[ "${create_issues}" == true ]]; then
			create_feedback_issues "${_feedback_actions_file}" "${dry_run}" || true
		fi
		# t2147: file contributor insights for contributor-role repos
		file_contributor_insights "${dry_run}" || true
		echo "--- Would log TODO suggestions to relevant repos ---"
	else
		echo "${summary}"
		echo "${feedback_output}"
		if [[ "${create_issues}" == true ]]; then
			create_feedback_issues "${_feedback_actions_file}" "${dry_run}" || true
		fi
		# t2147: file contributor insights for contributor-role repos
		file_contributor_insights "${dry_run}" || true
		record_pulse
		log_info "Pulse complete. Output: ${_output_dir}"
		log_info "Compressed signals: ${_compressed_file}"
		log_info "Feedback actions: ${_feedback_actions_file}"
		log_info "Feedback report: ${_feedback_report_file}"
		log_info "Run 'opencode run --dir ~/Git/REPO --title \"Session miner analysis\" \"Analyse ${_compressed_file} against the current harness and suggest improvements\"' for deep analysis."
	fi
	return 0
}

# file_contributor_insights files sanitized upstream issues for repos where
# the user is a contributor (role != maintainer). It re-extracts a repo-scoped
# compressed signal file for each target so unrelated project sessions cannot
# leak into contributor insight issues. Skips if no contributor-role repos found.
# Arguments: $1 — dry_run (true/false)
file_contributor_insights() {
	local dry_run="$1"

	local insight_helper="${SCRIPT_DIR}/contributor-insight-helper.sh"
	if [[ ! -x "$insight_helper" ]]; then
		return 0
	fi

	local repos_json="${HOME}/.config/aidevops/repos.json"
	if [[ ! -f "$repos_json" ]]; then
		return 0
	fi

	if ! command -v jq >/dev/null 2>&1; then
		return 0
	fi

	# Get current gh user for auto-detect
	local gh_user
	gh_user=$(gh api user --jq '.login' 2>/dev/null) || gh_user=""

	# Find contributor-role repos (explicit or auto-detected)
	local slug
	while IFS= read -r slug; do
		[[ -n "$slug" ]] || continue

		local repo_dir
		repo_dir=$(jq -r --arg s "$slug" '.initialized_repos[] | select(.slug == $s) | .path // empty' "$repos_json" 2>/dev/null) || repo_dir=""
		if [[ -z "$repo_dir" || ! -d "$repo_dir" ]]; then
			log_info "Skipping contributor insights for ${slug}: local repo path missing"
			continue
		fi

		# Check explicit role first
		local explicit_role
		explicit_role=$(jq -r --arg s "$slug" '.initialized_repos[] | select(.slug == $s) | .role // ""' "$repos_json" 2>/dev/null) || explicit_role=""

		local is_contributor=false
		if [[ "$explicit_role" == "contributor" ]]; then
			is_contributor=true
		elif [[ -z "$explicit_role" && -n "$gh_user" ]]; then
			# Auto-detect: different owner = contributor
			local owner="${slug%%/*}"
			if [[ "$owner" != "$gh_user" ]]; then
				is_contributor=true
			fi
		fi

		if [[ "$is_contributor" == true ]]; then
			log_info "Filing contributor insights for ${slug} scoped to ${repo_dir}..."
			local scoped_compressed_file
			scoped_compressed_file=$(run_repo_scoped_pipeline "${_db_path}" "${repo_dir}" "${slug}") || continue
			local dr_flag=""
			[[ "$dry_run" == true ]] && dr_flag="--dry-run"
			# shellcheck disable=SC2086
			"$insight_helper" file $dr_flag "${scoped_compressed_file}" "$slug" 2>&1 || true
		fi
	done < <(jq -r '.initialized_repos[] | select(.maintenance != false and .pulse == true and (.local_only // false) == false and .slug != "") | .slug' "$repos_json" 2>/dev/null)

	return 0
}

cleanup_old_pulses() {
	local old_dirs
	# head -n -7 is GNU-only; use awk to keep all except the last 7 (newest) entries
	old_dirs=$(find "${MINER_DIR}" -maxdepth 1 -type d -name "pulse_*" | sort | awk -v n=7 '{a[NR]=$0} END{for(i=1;i<=NR-n;i++) print a[i]}' 2>/dev/null || true)
	if [[ -n "${old_dirs}" ]]; then
		echo "${old_dirs}" | while read -r dir; do
			rm -rf "${dir}"
		done
		log_info "Cleaned up old pulse directories"
	fi
	return 0
}

# --- Main ---

main() {
	parse_args "$@" || return 1

	sync_scripts

	# Check interval (skip if too recent, unless forced)
	if [[ "${_force}" != true ]]; then
		check_interval || return 0
	fi

	# Acquire lock
	check_lock || return 0
	trap release_lock EXIT

	# Find and validate database
	local db_path
	db_path=$(detect_db "${_db_override}") || return 1
	_db_path="${db_path}"
	log_info "Using database: ${db_path}"

	validate_db_size "${db_path}" || {
		release_lock
		return 0
	}

	# Run extraction + compression pipeline
	run_pipeline "${db_path}" || {
		release_lock
		return 1
	}

	# Output results (summary, feedback, optional issue creation)
	output_results "${_dry_run}" "${_create_issues}" || {
		release_lock
		return 1
	}

	cleanup_old_pulses

	return 0
}

main "$@"
