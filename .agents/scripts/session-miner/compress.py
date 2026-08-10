#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Session Miner — Phase 2: Compress extracted chunks into analysis-ready summaries.

Takes the chunked extraction output and produces compact summaries that fit
within a single model context window for analysis.

Compression strategy:
1. Extract only user_text from steerage records (drop metadata noise)
2. Deduplicate near-identical texts
3. Strip file contents / diffs that were pasted (keep only the user's words)
4. Group by category with frequency counts
5. For errors: extract only the pattern (tool + error_category + recovery)
6. For instruction candidates: deduplicate, group by target file, rank by confidence

Target: <100KB total output that captures all unique signals.
"""

import argparse
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Optional

from compress_candidates import compress_instruction_candidates as _compress_instruction_candidates


DEFAULT_CHUNKS_DIR = Path.home() / ".aidevops/.agent-workspace/work/session-miner"
DEFAULT_OUTPUT_NAME = "compressed_signals.json"
INSTRUCTION_REDACTION_PLACEHOLDER = "[REDACTED secret-adjacent instruction candidate]"
INSTRUCTION_SECRET_ADJACENT_PATTERN = re.compile(
    r"\b(credential(?:s)?|password(?:s)?|token(?:s)?|api\s*key(?:s)?|secret(?:s)?|"
    r"authorization|bearer|private\s+key(?:s)?)\b",
    re.IGNORECASE,
)


def redact_instruction_candidate_text(text: str) -> str:
    """Return display-safe text for instruction-candidate snippets."""
    if INSTRUCTION_SECRET_ADJACENT_PATTERN.search(text):
        return INSTRUCTION_REDACTION_PLACEHOLDER
    return text


def parse_args(argv: Optional[list[str]] = None) -> argparse.Namespace:
    """Parse CLI arguments."""
    parser = argparse.ArgumentParser(
        description="Compress session-miner chunks into analysis-ready summaries",
    )
    parser.add_argument(
        "chunks_dir",
        nargs="?",
        type=Path,
        default=DEFAULT_CHUNKS_DIR,
        help=f"Directory containing extracted chunk JSON files (default: {DEFAULT_CHUNKS_DIR})",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=None,
        help="Output path for compressed JSON (default: <chunks_dir>/../compressed_signals.json)",
    )
    return parser.parse_args(argv)


def _load_json(path: Path) -> Optional[dict]:
    """Load a JSON object from disk, returning None on parse/read failure."""
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None


def _iter_chunks(chunks_dir: Path, pattern: str, *, skip: Optional[set[str]] = None):
    """Yield parsed chunk payloads matching a glob pattern."""
    skipped = skip or set()
    for chunk_file in sorted(chunks_dir.glob(pattern)):
        if chunk_file.name in skipped:
            continue
        chunk = _load_json(chunk_file)
        if chunk is not None:
            yield chunk


def _iter_chunk_records(chunks_dir: Path, pattern: str, *, skip: Optional[set[str]] = None):
    """Yield all records from parsed chunk payloads."""
    for chunk in _iter_chunks(chunks_dir, pattern, skip=skip):
        yield from chunk.get("records", [])


def strip_file_content(text: str) -> str:
    """Remove pasted file contents, diffs, and code blocks from user text.
    
    Keep only the user's actual words/instructions.
    """
    # Remove <file>...</file> blocks
    text = re.sub(r'<file>.*?</file>', '[file content]', text, flags=re.DOTALL)
    
    # Remove diff blocks — match from "diff --git" to the next "diff --git" header
    # or end of string, capturing the full block (index line, ---, +++, @@ hunks, etc.)
    text = re.sub(r'diff --git .*?(?=\ndiff --git |\Z)', '[diff]', text, flags=re.DOTALL)
    
    # Remove lines that are clearly file content (numbered lines like "00001| ...")
    text = re.sub(r'\n\d{5}\|.*', '', text)
    
    # Remove URL-heavy lines (SonarCloud links etc)
    text = re.sub(r'https?://\S{80,}', '[url]', text)
    
    # Remove code blocks
    text = re.sub(r'```.*?```', '[code]', text, flags=re.DOTALL)
    
    # Collapse whitespace
    text = re.sub(r'\n{3,}', '\n\n', text)
    
    return text.strip()


def is_automated_message(text: str) -> bool:
    """Detect automated/templated messages that aren't real user steerage."""
    automated_patterns = [
        r'^/full-loop\b',
        r'^"You are the supervisor',
        r'^Continue if you have next steps',
        r'^Review the following potential duplicate',
        r'^Analyze the changes made since',
        r'^<file>\n\d{5}\|',
        r'^diff --git',
    ]
    for pattern in automated_patterns:
        if re.match(pattern, text, re.MULTILINE):
            return True
    return False


def normalize_for_dedup(text: str) -> str:
    """Normalize text for deduplication."""
    t = text.lower().strip()
    t = re.sub(r'\s+', ' ', t)
    t = re.sub(r'[^\w\s]', '', t)
    return t[:200]  # First 200 chars for comparison


def _extract_steerage_signal(record: dict):
    """Extract a cleaned, deduplicated signal from a steerage record.

    Returns a signal dict or None if the record should be skipped.
    """
    raw_text = record.get("user_text", "")
    if not raw_text or len(raw_text) < 25:
        return None

    if is_automated_message(raw_text):
        return None

    clean_text = strip_file_content(raw_text)
    if len(clean_text) < 20:
        return None

    return {
        "text": clean_text[:1000],
        "context": record.get("preceding_context", "")[:200],
        "source_hash": record.get("source_hash", ""),
    }


def compress_steerage(chunks_dir: Path) -> dict:
    """Compress all steerage chunks into category-grouped unique signals."""
    categories = defaultdict(list)
    seen_by_category: dict[str, set[str]] = defaultdict(set)

    for chunk in _iter_chunks(chunks_dir, "steerage_*.json"):
        for record in chunk.get("records", []):
            signal = _extract_steerage_signal(record)
            if signal is None:
                continue
            record_categories = {
                classification.get("category", "unknown")
                for classification in record.get("classifications", [])
            } or {chunk.get("category", "unknown")}
            norm = normalize_for_dedup(signal["text"])
            for category in record_categories:
                if norm in seen_by_category[category]:
                    continue
                seen_by_category[category].add(norm)
                categories[category].append(signal)

    return dict(categories)


_SEVERITY_RANK = {
    "permission": "high",
    "not_read_first": "high",
    "edit_stale_read": "medium",
    "edit_mismatch": "medium",
    "edit_multiple": "medium",
    "workdir_not_found": "medium",
    "file_not_found": "medium",
    "timeout": "low",
    "exit_code": "low",
    "other": "low",
}


def _accumulate_error_record(record: dict, pattern_counts, pattern_examples,
                             recovery_patterns, pattern_models):
    """Accumulate a single error record into the pattern aggregation structures."""
    tool = record.get("tool", "unknown")
    cat = record.get("error_category", "other")
    key = f"{tool}:{cat}"

    pattern_counts[key] += 1
    model_id = record.get("model") or "unknown"
    pattern_models[key].add(model_id)

    if len(pattern_examples[key]) < 3:
        example = {
            "error": record.get("error_text", "")[:200],
            "input": record.get("tool_input_summary", ""),
            "user_response": record.get("user_response", "")[:200] if record.get("user_response") else None,
        }
        pattern_examples[key].append(example)

    recovery = record.get("recovery")
    if recovery:
        recovery_desc = f"{recovery.get('tool', '')}: {recovery.get('approach', '')}"
        if recovery_desc not in recovery_patterns[key]:
            recovery_patterns[key].append(recovery_desc)


def _build_error_patterns(pattern_counts, pattern_examples, recovery_patterns, pattern_models):
    """Build the final compressed error summary from aggregated data."""
    error_patterns = []
    for key, count in pattern_counts.most_common():
        tool, cat = key.split(":", 1)
        models = sorted(pattern_models.get(key, set()))
        model_count = len(models)
        error_patterns.append({
            "tool": tool,
            "error_category": cat,
            "count": count,
            "models": models,
            "model_count": model_count,
            "cross_model": model_count >= 2,
            "severity": _SEVERITY_RANK.get(cat, "low"),
            "examples": pattern_examples[key],
            "recovery_patterns": recovery_patterns.get(key, [])[:3],
        })
    return error_patterns


def compress_errors(chunks_dir: Path) -> dict:
    """Compress error chunks into pattern summaries."""
    pattern_counts = Counter()
    pattern_examples = defaultdict(list)
    recovery_patterns = defaultdict(list)
    pattern_models = defaultdict(set)

    for record in _iter_chunk_records(chunks_dir, "error_*.json"):
        _accumulate_error_record(record, pattern_counts, pattern_examples,
                                 recovery_patterns, pattern_models)

    return {"patterns": _build_error_patterns(pattern_counts, pattern_examples,
                                                recovery_patterns, pattern_models)}


def _load_git_summary(chunks_dir: Path) -> dict:
    """Load the git summary chunk payload, if present."""
    chunk = _load_json(chunks_dir / "git_summary.json")
    if chunk is None:
        return {}
    return chunk.get("data", {})


def _collect_git_sessions(chunks_dir: Path):
    """Collect git-correlation session records grouped by project."""
    by_project = defaultdict(list)
    all_sessions = []
    for record in _iter_chunk_records(chunks_dir, "git_*.json", skip={"git_summary.json"}):
        project = record.get("session_dir", "unknown")
        by_project[project].append(record)
        all_sessions.append(record)
    return by_project, all_sessions


def _build_project_stats(by_project: dict[str, list[dict]]) -> dict[str, dict]:
    """Build per-project git productivity summaries."""
    project_stats = {}
    for project, sessions in sorted(by_project.items(), key=lambda item: -len(item[1])):
        productive = [s for s in sessions if s.get("commits_count", 0) > 0]
        total_commits = sum(s.get("commits_count", 0) for s in sessions)
        total_insertions = sum(s.get("insertions", 0) for s in sessions)
        total_deletions = sum(s.get("deletions", 0) for s in sessions)
        project_stats[project] = {
            "sessions": len(sessions),
            "productive_sessions": len(productive),
            "total_commits": total_commits,
            "total_lines_changed": total_insertions + total_deletions,
            "avg_commits_per_message": round(
                sum(s.get("commits_per_message", 0) for s in productive)
                / max(len(productive), 1), 3,
            ),
        }
    return project_stats


def _build_top_productive_sessions(all_sessions: list[dict]) -> list[dict]:
    """Return the most productive git-correlation sessions."""
    top_productive = sorted(
        [s for s in all_sessions if s.get("commits_count", 0) >= 2],
        key=lambda session: session.get("commits_per_message", 0),
        reverse=True,
    )[:10]
    return [
        {
            "title": session.get("session_title", "")[:100],
            "project": session.get("session_dir", ""),
            "commits": session.get("commits_count", 0),
            "messages": session.get("user_messages", 0),
            "ratio": session.get("commits_per_message", 0),
            "duration_min": session.get("duration_minutes", 0),
        }
        for session in top_productive
    ]


def compress_git_correlation(chunks_dir: Path) -> dict:
    """Compress git correlation chunks into productivity summaries.

    Groups sessions by project, computes per-project and overall productivity
    metrics, and identifies the most/least productive session patterns.
    """
    summary = _load_git_summary(chunks_dir)
    by_project, all_sessions = _collect_git_sessions(chunks_dir)

    return {
        "summary": summary,
        "project_stats": _build_project_stats(by_project),
        "top_productive_sessions": _build_top_productive_sessions(all_sessions),
    }


def compress_instruction_candidates(chunks_dir: Path) -> dict:
    """Compress instruction candidate chunks into deduplicated, ranked summaries.

    Groups by target file, deduplicates near-identical texts, and ranks by
    confidence score. Returns a dict keyed by target file with candidate lists.
    """
    return _compress_instruction_candidates(
        _iter_chunk_records(chunks_dir, "instruction_candidate_*.json"),
        redact_instruction_candidate_text,
        normalize_for_dedup,
    )


def _load_stats(chunks_dir: Path) -> dict:
    """Load the extracted stats chunk, if present."""
    chunk = _load_json(chunks_dir / "stats.json")
    if chunk is None:
        return {}
    return chunk.get("data", {})


def _print_output_summary(output_path: Path, output: dict):
    """Print the compression summary to stderr."""
    steerage = output["steerage"]
    errors = output["errors"]
    instruction_candidates = output["instruction_candidates"]
    git_summary = output["git_correlation"].get("summary", {})

    total_steerage = sum(len(v) for v in steerage.values())
    total_errors = len(errors.get("patterns", []))
    total_candidates = sum(len(v) for v in instruction_candidates.values())
    file_size = output_path.stat().st_size

    print(f"Output: {output_path}", file=sys.stderr)
    print(f"  {total_steerage} unique steerage signals", file=sys.stderr)
    print(f"  {total_errors} error patterns", file=sys.stderr)
    print(f"  {total_candidates} instruction candidates", file=sys.stderr)
    print(f"  {file_size / 1024:.1f} KB", file=sys.stderr)

    for cat, signals in sorted(steerage.items(), key=lambda item: -len(item[1])):
        print(f"  steerage/{cat}: {len(signals)} unique signals", file=sys.stderr)

    for target_file, candidates in sorted(instruction_candidates.items()):
        print(f"  instruction_candidates/{target_file}: {len(candidates)} candidates", file=sys.stderr)

    if git_summary:
        print(
            f"  git: {git_summary.get('productive_sessions', 0)}"
            f"/{git_summary.get('total_sessions', 0)} productive sessions,"
            f" {git_summary.get('total_commits', 0)} commits",
            file=sys.stderr,
        )


def main(argv: Optional[list[str]] = None):
    args = parse_args(argv)
    chunks_dir = args.chunks_dir
    output_path = args.output or (chunks_dir.parent / DEFAULT_OUTPUT_NAME)

    if not chunks_dir.exists():
        print(f"Error: Chunks directory not found at {chunks_dir}", file=sys.stderr)
        sys.exit(1)

    print(f"Compressing chunks from {chunks_dir}", file=sys.stderr)

    steerage = compress_steerage(chunks_dir)
    errors = compress_errors(chunks_dir)
    git_correlation = compress_git_correlation(chunks_dir)
    instruction_candidates = compress_instruction_candidates(chunks_dir)

    stats = _load_stats(chunks_dir)

    output = {
        "steerage": steerage,
        "steerage_counts": {k: len(v) for k, v in steerage.items()},
        "errors": errors,
        "stats": stats,
        "git_correlation": git_correlation,
        "instruction_candidates": instruction_candidates,
        "instruction_candidates_counts": {k: len(v) for k, v in instruction_candidates.items()},
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(output, indent=2, ensure_ascii=False), encoding="utf-8")
    _print_output_summary(output_path, output)


if __name__ == "__main__":
    main()
