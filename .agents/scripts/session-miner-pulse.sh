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
MINER_DIR="${SESSION_MINER_MINER_DIR:-${HOME}/.aidevops/.agent-workspace/session-miner}"
# Shipped with aidevops; copied to workspace on first run
EXTRACTOR_SRC="${SESSION_MINER_EXTRACTOR_SRC:-${SCRIPT_DIR}/session-miner/extract.py}"
COMPRESSOR_SRC="${SESSION_MINER_COMPRESSOR_SRC:-${SCRIPT_DIR}/session-miner/compress.py}"
EXTRACTOR="${MINER_DIR}/extract.py"
COMPRESSOR="${MINER_DIR}/compress.py"
STATE_FILE="${MINER_DIR}/state.json"
LEGACY_STATE_FILE="${SESSION_MINER_LEGACY_STATE_FILE:-${HOME}/.aidevops/.agent-workspace/work/session-miner/.last-pulse}"
LOCK_DIR="${MINER_DIR}/.pulse.lock"
ACTUATION_HELPER="${SESSION_MINER_ACTUATION_HELPER:-${SCRIPT_DIR}/session-miner-actuation-helper.sh}"
REPOS_JSON="${REPOS_JSON:-${HOME}/.config/aidevops/repos.json}"

# Default: OpenCode DB
DEFAULT_DB="${SESSION_MINER_DEFAULT_DB:-${HOME}/.local/share/opencode/opencode.db}"

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

now_epoch() {
	local configured="${SESSION_MINER_NOW_EPOCH:-}"
	if [[ "$configured" =~ ^[0-9]+$ ]]; then
		printf '%s' "$configured"
		return 0
	fi
	date +%s
	return 0
}

state_existing_json() {
	if [[ -f "$STATE_FILE" ]] && jq -e 'type == "object"' "$STATE_FILE" >/dev/null 2>&1; then
		jq -c . "$STATE_FILE"
		return $?
	fi
	local legacy_epoch=0
	if [[ -f "$LEGACY_STATE_FILE" ]]; then
		legacy_epoch=$(<"$LEGACY_STATE_FILE")
		[[ "$legacy_epoch" =~ ^[0-9]+$ ]] || legacy_epoch=0
	fi
	jq -cn --argjson legacy_epoch "$legacy_epoch" '
		if $legacy_epoch > 0 then {
			schema_version: 1,
			status: "legacy_migrated",
			last_attempt_epoch: $legacy_epoch,
			last_success_epoch: $legacy_epoch,
			source_watermark_ms: null,
			duration_seconds: 0,
			counts: {},
			error_class: null,
			fingerprints: []
		} else {} end
	'
	return 0
}

state_write() {
	local status="$1"
	local error_class="$2"
	local duration_seconds="$3"
	local counts_json="$4"
	local watermark="$5"
	local fingerprints_json="$6"
	local mark_success="$7"
	local now=0 existing='{}' tmp_file=""
	now=$(now_epoch)
	existing=$(state_existing_json) || existing='{}'
	mkdir -p "$MINER_DIR"
	tmp_file=$(mktemp "${MINER_DIR}/.state.XXXXXX") || return 1
	if ! printf '%s' "$existing" | jq \
		--arg status "$status" \
		--arg error_class "$error_class" \
		--arg watermark "$watermark" \
		--argjson now "$now" \
		--argjson interval "$MIN_INTERVAL" \
		--argjson duration "$duration_seconds" \
		--argjson counts "$counts_json" \
		--argjson fingerprints "$fingerprints_json" \
		--argjson mark_success "$mark_success" '
		.schema_version = 1
		| .status = $status
		| .last_attempt_epoch = $now
		| .duration_seconds = $duration
		| .counts = $counts
		| .error_class = (if $error_class == "" then null else $error_class end)
		| .fingerprints = (((.fingerprints // []) + $fingerprints) | unique)
		| if $mark_success then
			.last_success_epoch = $now
			| if ($watermark | test("^[0-9]+$")) then .source_watermark_ms = ($watermark | tonumber) else . end
		  else . end
		| .schedule = {
			interval_seconds: $interval,
			next_due_epoch: ((.last_success_epoch // 0) + $interval)
		}
	' >"$tmp_file"; then
		rm -f "$tmp_file"
		return 1
	fi
	mv "$tmp_file" "$STATE_FILE"
	return 0
}

state_status_json() {
	local now=0 existing='{}'
	now=$(now_epoch)
	existing=$(state_existing_json) || existing='{}'
	printf '%s' "$existing" | jq \
		--argjson now "$now" \
		--argjson interval "$MIN_INTERVAL" '
		.schema_version = 1
		| .status = (.status // "never_run")
		| .schedule = ((.schedule // {}) + {
			interval_seconds: $interval,
			next_due_epoch: ((.last_success_epoch // 0) + $interval),
			due: ($now >= ((.last_success_epoch // 0) + $interval))
		})
		| .freshness = {
			last_attempt_epoch: (.last_attempt_epoch // null),
			last_success_epoch: (.last_success_epoch // null),
			stale: (($now - (.last_success_epoch // 0)) > ($interval * 2))
		}
		| .source_watermark_ms = (.source_watermark_ms // null)
		| .duration_seconds = (.duration_seconds // 0)
		| .counts = (.counts // {})
		| .error_class = (.error_class // null)
		| .fingerprints = (.fingerprints // [])
	'
	return $?
}

print_status() {
	local json_output="$1"
	local health='{}'
	health=$(state_status_json) || return 1
	if [[ "$json_output" == true ]]; then
		printf '%s\n' "$health"
	else
		printf 'session-miner: %s; due=%s; last_success=%s; watermark_ms=%s; error=%s\n' \
			"$(printf '%s' "$health" | jq -r '.status')" \
			"$(printf '%s' "$health" | jq -r '.schedule.due')" \
			"$(printf '%s' "$health" | jq -r '.freshness.last_success_epoch // "never"')" \
			"$(printf '%s' "$health" | jq -r '.source_watermark_ms // "none"')" \
			"$(printf '%s' "$health" | jq -r '.error_class // "none"')"
	fi
	return 0
}

check_lock() {
	mkdir -p "$MINER_DIR"
	if mkdir "$LOCK_DIR" 2>/dev/null; then
		printf '%s\n' "$$" >"${LOCK_DIR}/pid"
		return 0
	fi
	if [[ -d "$LOCK_DIR" ]]; then
		local lock_age lock_mtime lock_pid=""
		lock_mtime=$(_file_mtime_epoch "$LOCK_DIR")
		lock_age=$(($(now_epoch) - lock_mtime))
		[[ "$lock_age" -ge 0 ]] || lock_age=0
		if [[ -f "${LOCK_DIR}/pid" ]]; then
			lock_pid=$(<"${LOCK_DIR}/pid")
		fi
		if [[ "$lock_pid" =~ ^[0-9]+$ ]] && kill -0 "$lock_pid" 2>/dev/null; then
			log_info "Another pulse is running (pid: ${lock_pid}, lock age: ${lock_age}s). Exiting."
			return 1
		fi
		# Stale lock (>1 hour)
		if [[ "${lock_age}" -gt 3600 ]]; then
			log_info "Removing stale lock (${lock_age}s old)"
			rm -rf "$LOCK_DIR"
			if mkdir "$LOCK_DIR" 2>/dev/null; then
				printf '%s\n' "$$" >"${LOCK_DIR}/pid"
				return 0
			fi
		else
			log_info "Another pulse is running (lock age: ${lock_age}s). Exiting."
			return 1
		fi
	fi
	return 1
}

release_lock() {
	local lock_pid=""
	if [[ -f "${LOCK_DIR}/pid" ]]; then
		lock_pid=$(<"${LOCK_DIR}/pid")
	fi
	if [[ "$lock_pid" == "$$" ]]; then
		rm -rf "$LOCK_DIR"
	fi
	return 0
}

check_interval() {
	local existing='{}' last_run=0 now=0
	existing=$(state_existing_json) || existing='{}'
	last_run=$(printf '%s' "$existing" | jq -r '.last_success_epoch // 0') || last_run=0
	now=$(now_epoch)
	if [[ "$last_run" =~ ^[0-9]+$ && "$last_run" -gt 0 ]]; then
		local elapsed=$((now - last_run))
		if [[ "${elapsed}" -lt "${MIN_INTERVAL}" ]]; then
			local remaining=$((MIN_INTERVAL - elapsed))
			log_info "Last pulse was ${elapsed}s ago. Next in ${remaining}s. Skipping."
			return 1
		fi
	fi
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
	local since_ms="$3"

	if [[ ! -f "${EXTRACTOR}" ]]; then
		log_error "Extractor not found at ${EXTRACTOR}"
		return 1
	fi

	log_info "Running extraction from ${db_path}..."
	local -a args=(--db "$db_path" --format chunks --output "$output_dir")
	[[ -z "$since_ms" ]] || args+=(--since-ms "$since_ms")
	python3 "$EXTRACTOR" "${args[@]}" 2>&1
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
	local since_ms="$4"

	if [[ ! -f "${EXTRACTOR}" ]]; then
		log_error "Extractor not found at ${EXTRACTOR}"
		return 1
	fi

	log_info "Running repo-scoped extraction from ${db_path} for ${repo_dir}..."
	local -a args=(--db "$db_path" --format chunks --output "$output_dir" --repo-dir "$repo_dir")
	[[ -z "$since_ms" ]] || args+=(--since-ms "$since_ms")
	python3 "$EXTRACTOR" "${args[@]}" 2>&1
	return $?
}

first_chunks_dir() {
	local output_dir="$1"
	local candidate=""
	for candidate in "$output_dir"/chunks_*; do
		if [[ -d "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

run_repo_scoped_pipeline() {
	local db_path="$1"
	local repo_dir="$2"
	local slug="$3"
	local since_ms="$4"

	local slug_safe
	slug_safe="${slug//\//_}"
	local scoped_output_dir="${_output_dir}/contributor_${slug_safe}"
	mkdir -p "${scoped_output_dir}"

	local extract_output
	extract_output=$(run_repo_scoped_extraction "$db_path" "$scoped_output_dir" "$repo_dir" "$since_ms" 2>&1) || {
		log_error "Repo-scoped extraction failed for ${slug}: ${extract_output}"
		return 1
	}

	local chunks_dir
	chunks_dir=$(first_chunks_dir "$scoped_output_dir") || chunks_dir=""
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

# --- Main helpers ---

parse_since_ms() {
	local value="$1"
	if [[ "$value" =~ ^[0-9]{13}$ ]]; then
		printf '%s' "$value"
		return 0
	fi
	local pattern='^([0-9]+)(s|m|h|d)$'
	if [[ "$value" =~ $pattern ]]; then
		local amount="${BASH_REMATCH[1]}"
		local unit="${BASH_REMATCH[2]}"
		local multiplier=1
		case "$unit" in
		s) multiplier=1 ;;
		m) multiplier=60 ;;
		h) multiplier=3600 ;;
		d) multiplier=86400 ;;
		esac
		local now=0 since_epoch=0
		now=$(now_epoch)
		since_epoch=$((now - (amount * multiplier)))
		[[ "$since_epoch" -ge 0 ]] || since_epoch=0
		printf '%s' $((since_epoch * 1000))
		return 0
	fi
	log_error "Invalid --since value: ${value}; use epoch milliseconds or <number>[s|m|h|d]"
	return 1
}

# parse_args sets script-level command and pipeline options.
parse_args() {
	_db_override=""
	_dry_run=false
	_force=false
	_create_issues=false
	_status_only=false
	_json_output=false
	_since_override_ms=""

	while [[ $# -gt 0 ]]; do
		case "$1" in
		--db)
			[[ $# -ge 2 ]] || return 1
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
			[[ $# -ge 2 ]] || return 1
			_since_override_ms=$(parse_since_ms "$2") || return 1
			shift 2
			;;
		--status)
			_status_only=true
			shift
			;;
		--json)
			_json_output=true
			shift
			;;
		*)
			log_error "Unknown argument: $1"
			return 1
			;;
		esac
	done
	if [[ "$_json_output" == true && "$_status_only" != true ]]; then
		log_error "--json currently requires --status"
		return 1
	fi
	return 0
}

sync_scripts() {
	mkdir -p "${MINER_DIR}"
	# Copy all Python modules from source to workspace (not just extract.py + compress.py).
	# Resilient to future refactoring: any new .py added to scripts/session-miner/ is
	# automatically deployed. Fixes regression from t1944 which added 5 helper modules
	# (extract_chunking.py, extract_errors.py, extract_git.py, extract_shared.py,
	# extract_steerage.py) without updating this copy logic. Ref: GH#18383.
	local _miner_src_dir="${EXTRACTOR_SRC%/*}"
	local _py_src
	local _py_dst
	for _py_src in "${_miner_src_dir}"/*.py; do
		[[ -f "${_py_src}" ]] || continue
		_py_dst="${MINER_DIR}/$(basename "${_py_src}")"
		if [[ ! -f "${_py_dst}" || "${_py_src}" -nt "${_py_dst}" ]]; then
			cp "${_py_src}" "${_py_dst}"
		fi
	done
	if [[ -f "$COMPRESSOR_SRC" ]]; then
		_py_dst="${MINER_DIR}/compress.py"
		if [[ ! -f "$_py_dst" || "$COMPRESSOR_SRC" -nt "$_py_dst" ]]; then
			cp "$COMPRESSOR_SRC" "$_py_dst"
		fi
	fi
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
validate_compressed_metadata() {
	local compressed_file="$1"
	local since_ms="$2"
	jq -e --arg since "$since_ms" '
		.stats.extraction_metadata as $metadata
		| ($metadata | type) == "object"
		and ($metadata | has("window_start_ms"))
		and ($metadata | has("source_high_water_ms"))
		and (if $since == "" then $metadata.window_start_ms == null else $metadata.window_start_ms == ($since | tonumber) end)
		and (($metadata.source_high_water_ms == null) or (($metadata.source_high_water_ms | type) == "number"))
	' "$compressed_file" >/dev/null 2>&1
	return $?
}

run_pipeline() {
	local db_path="$1"
	local since_ms="$2"
	_pipeline_error_class=""
	if ! python3 "$EXTRACTOR" --help 2>&1 | grep -q -- '--since-ms'; then
		log_error "Extractor does not expose the required --since-ms capability"
		_pipeline_error_class="extractor_capability_missing"
		return 1
	fi

	local run_ts
	run_ts=$(date +%Y%m%d_%H%M%S)
	_output_dir=$(mktemp -d "${MINER_DIR}/pulse_${run_ts}.XXXXXX") || {
		_pipeline_error_class="output_directory_failed"
		return 1
	}

	local extract_output
	extract_output=$(run_extraction "$db_path" "$_output_dir" "$since_ms" 2>&1) || {
		log_error "Extraction failed: ${extract_output}"
		_pipeline_error_class="extraction_failed"
		return 1
	}

	local chunks_dir
	chunks_dir=$(first_chunks_dir "$_output_dir") || chunks_dir=""
	if [[ -z "${chunks_dir}" ]]; then
		log_error "No chunks directory found in ${_output_dir}"
		_pipeline_error_class="extraction_output_missing"
		return 1
	fi

	run_compression "${chunks_dir}" 2>&1 || {
		log_error "Compression failed"
		_pipeline_error_class="compression_failed"
		return 1
	}

	_compressed_file="${_output_dir}/compressed_signals.json"
	_feedback_actions_file="${MINER_DIR}/feedback_actions.json"
	_feedback_report_file="${MINER_DIR}/feedback_actions.md"
	_feedback_metrics_file="${MINER_DIR}/feedback_metrics.json"

	if [[ ! -f "${_compressed_file}" ]]; then
		log_error "Compressed signals file not produced at ${_compressed_file}"
		_pipeline_error_class="compression_output_missing"
		return 1
	fi
	if ! validate_compressed_metadata "$_compressed_file" "$since_ms"; then
		log_error "Compressed output lacks compatible extraction watermark metadata"
		_pipeline_error_class="watermark_validation_failed"
		return 1
	fi
	_new_watermark_ms=$(jq -r '.stats.extraction_metadata.source_high_water_ms // empty' "$_compressed_file") || _new_watermark_ms=""
	_counts_json=$(jq -c '{
		steerage: ([.steerage // {} | .[] | length] | add // 0),
		errors: ((.errors.patterns // []) | length),
		instruction_candidates: ([.instruction_candidates // {} | .[] | length] | add // 0),
		actuated: 0
	}' "$_compressed_file") || {
		_pipeline_error_class="count_validation_failed"
		return 1
	}
	return 0
}

# output_results prints summary and feedback, optionally creates issues,
# and records the pulse timestamp when not in dry-run mode.
output_results() {
	local dry_run="$1"

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
		echo "--- Would evaluate qualified role-routed actuation candidates ---"
	else
		echo "${summary}"
		echo "${feedback_output}"
		log_info "Pulse complete. Output: ${_output_dir}"
		log_info "Compressed signals: ${_compressed_file}"
		log_info "Feedback actions: ${_feedback_actions_file}"
		log_info "Feedback report: ${_feedback_report_file}"
		log_info "Run 'opencode run --dir ~/Git/REPO --title \"Session miner analysis\" \"Analyse ${_compressed_file} against the current harness and suggest improvements\"' for deep analysis."
	fi
	return 0
}

run_actuation() {
	local since_ms="$1"
	_actuation_fingerprints='[]'
	_actuation_status="healthy"
	[[ "$_create_issues" == true ]] || return 0
	[[ "$_dry_run" != true ]] || return 0
	[[ -x "$ACTUATION_HELPER" && -f "$REPOS_JSON" ]] || return 1

	local known_fingerprints='[]'
	known_fingerprints=$(state_existing_json | jq -c '.fingerprints // []') || known_fingerprints='[]'
	local framework_entry='{}' framework_path="" framework_slug="" framework_signals="" result="" receipts='[]'
	framework_entry=$(jq -c '
		[.initialized_repos[]? | select(.slug == "marcusquinn/aidevops" and .role == "maintainer")]
		| if length == 1 then .[0] else {} end
	' "$REPOS_JSON" 2>/dev/null) || framework_entry='{}'
	framework_path=$(printf '%s' "$framework_entry" | jq -r '.path // ""') || framework_path=""
	framework_slug=$(printf '%s' "$framework_entry" | jq -r '.slug // ""') || framework_slug=""
	if [[ -z "$framework_slug" ]]; then
		_actuation_status="skipped_no_framework_registration"
		_counts_json=$(printf '%s' "$_counts_json" | jq -c '.actuated = 0') || return 1
		return 0
	fi
	[[ -n "$framework_path" && -d "$framework_path" ]] || return 1
	framework_signals=$(run_repo_scoped_pipeline "$_db_path" "$framework_path" "$framework_slug" "$since_ms") || return 1
	validate_compressed_metadata "$framework_signals" "$since_ms" || return 1
	result=$("$ACTUATION_HELPER" maintainer --signals "$framework_signals" --repos "$REPOS_JSON" \
		--known-fingerprints "$known_fingerprints") || return 1
	receipts=$(printf '%s' "$result" | jq -c '.fingerprints // []') || return 1
	_actuation_fingerprints=$(printf '%s' "$_actuation_fingerprints" | jq -c --argjson receipts "$receipts" '. + $receipts | unique') || return 1

	local contributor_entry=""
	while IFS= read -r contributor_entry; do
		[[ -n "$contributor_entry" ]] || continue
		local slug="" repo_dir="" scoped_signals=""
		slug=$(printf '%s' "$contributor_entry" | jq -r '.slug') || return 1
		repo_dir=$(printf '%s' "$contributor_entry" | jq -r '.path // ""') || return 1
		[[ -n "$repo_dir" && -d "$repo_dir" ]] || return 1
		scoped_signals=$(run_repo_scoped_pipeline "$_db_path" "$repo_dir" "$slug" "$since_ms") || return 1
		validate_compressed_metadata "$scoped_signals" "$since_ms" || return 1
		result=$("$ACTUATION_HELPER" contributor --signals "$scoped_signals" --repos "$REPOS_JSON" --slug "$slug") || return 1
		receipts=$(printf '%s' "$result" | jq -c '.fingerprints // []') || return 1
		_actuation_fingerprints=$(printf '%s' "$_actuation_fingerprints" | jq -c --argjson receipts "$receipts" '. + $receipts | unique') || return 1
	done < <(jq -c '.initialized_repos[]? | select(.maintenance != false and .pulse == true and .role == "contributor")' "$REPOS_JSON" 2>/dev/null)

	_counts_json=$(printf '%s' "$_counts_json" | jq -c --argjson count "$(printf '%s' "$_actuation_fingerprints" | jq 'length')" '.actuated = $count') || return 1
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

record_failed_run() {
	local error_class="$1"
	local started_epoch="$2"
	local status="${3:-failed}"
	local ended_epoch=0 duration=0 counts='{}'
	ended_epoch=$(now_epoch)
	duration=$((ended_epoch - started_epoch))
	[[ "$duration" -ge 0 ]] || duration=0
	if [[ -n "${_counts_json:-}" ]]; then
		counts="$_counts_json"
	else
		counts=$(state_existing_json | jq -c '.counts // {}') || counts='{}'
	fi
	if [[ "${_dry_run:-false}" != true ]]; then
		state_write "$status" "$error_class" "$duration" "$counts" keep '[]' false || true
	fi
	return 0
}

# --- Main ---

main() {
	parse_args "$@" || return 1
	if ! [[ "$MIN_INTERVAL" =~ ^[0-9]+$ && "$MIN_INTERVAL" -gt 0 ]]; then
		log_error "SESSION_MINER_INTERVAL must be a positive integer"
		return 1
	fi
	if [[ "$_status_only" == true ]]; then
		print_status "$_json_output"
		return $?
	fi

	sync_scripts

	# Check interval (skip if too recent, unless forced)
	if [[ "${_force}" != true ]]; then
		if ! check_interval; then
			local existing_counts='{}'
			existing_counts=$(state_existing_json | jq -c '.counts // {}') || existing_counts='{}'
			[[ "$_dry_run" == true ]] || state_write not_due "" 0 "$existing_counts" keep '[]' false
			return 0
		fi
	fi

	# Acquire lock
	check_lock || return 0
	trap release_lock EXIT
	local started_epoch=0
	started_epoch=$(now_epoch)
	local existing_counts='{}'
	existing_counts=$(state_existing_json | jq -c '.counts // {}') || existing_counts='{}'
	[[ "$_dry_run" == true ]] || state_write running "" 0 "$existing_counts" keep '[]' false || return 1

	# Find and validate database
	local db_path
	db_path=$(detect_db "${_db_override}") || {
		record_failed_run database_unavailable "$started_epoch"
		return 1
	}
	_db_path="${db_path}"
	log_info "Using database: ${db_path}"

	validate_db_size "${db_path}" || {
		[[ "$_dry_run" == true ]] || state_write healthy "" 0 '{"steerage":0,"errors":0,"instruction_candidates":0,"actuated":0}' keep '[]' true
		return 0
	}

	local since_ms="$_since_override_ms"
	if [[ -z "$since_ms" ]]; then
		since_ms=$(state_existing_json | jq -r '.source_watermark_ms // empty') || since_ms=""
	fi
	_counts_json=""
	_new_watermark_ms=""
	_actuation_fingerprints='[]'
	_actuation_status="healthy"

	# Run extraction + compression pipeline
	run_pipeline "$db_path" "$since_ms" || {
		record_failed_run "${_pipeline_error_class:-pipeline_failed}" "$started_epoch"
		return 1
	}
	local replayed_interval=false
	if [[ -n "$since_ms" && "$_new_watermark_ms" == "$since_ms" ]]; then
		replayed_interval=true
		_counts_json=$(state_existing_json | jq -c '.counts // {}') || _counts_json='{}'
	fi

	# Generate local reports before any network write.
	output_results "${_dry_run}" || {
		record_failed_run report_generation_failed "$started_epoch"
		return 1
	}
	if [[ "$replayed_interval" != true ]] && ! run_actuation "$since_ms"; then
		record_failed_run actuation_deferred "$started_epoch" deferred
		return 1
	fi

	if [[ "$_dry_run" != true ]]; then
		local ended_epoch=0 duration=0 watermark="$_new_watermark_ms"
		ended_epoch=$(now_epoch)
		duration=$((ended_epoch - started_epoch))
		[[ "$duration" -ge 0 ]] || duration=0
		[[ -n "$watermark" ]] || watermark="$since_ms"
		state_write "$_actuation_status" "" "$duration" "$_counts_json" "$watermark" "$_actuation_fingerprints" true || return 1
	fi

	cleanup_old_pulses

	return 0
}

main "$@"
