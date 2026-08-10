#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""
Session Miner — Phase 1: Extract high-signal data from coding assistant sessions.

Extracts four categories of learning signal from local session databases:
1. User steerage: corrections, preferences, guidance, workflow patterns
2. Model errors: tool failures with surrounding context (what failed, what fixed it)
3. Git correlation: cross-references sessions with git commit outcomes
4. Instruction candidates: persistent guidance/corrections that should be saved to
   instruction files (AGENTS.md, build.txt, style guides)

Output format is tool-agnostic — works with OpenCode now, adaptable to
Claude Code, Cursor, or any tool that stores session data.

All data stays local. Output goes to ~/.aidevops/.agent-workspace/work/session-miner/

Usage:
    python3 extract.py                    # Extract from default OpenCode DB
    python3 extract.py --db /path/to.db   # Custom DB path
    python3 extract.py --format jsonl     # JSONL output (default)
    python3 extract.py --format chunks    # Pre-chunked for model analysis
    python3 extract.py --limit 100        # Limit sessions processed
    python3 extract.py --no-git           # Skip git correlation extraction
"""

import argparse
import hashlib
import json
import re
import sqlite3
import subprocess
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from extract_chunking import ChunkConfig, build_chunks
from extract_errors import extract_error_stats, extract_errors
from extract_git import extract_git_correlation
from extract_shared import (
    extraction_scope_params,
    repo_scope_clause,
    sanitize_path as _sanitize_path,
    time_scope_clause,
)
from extract_steerage import (
    STEERAGE_PATTERNS,
    extract_steerage,
    fetch_text_parts as _fetch_text_parts,
    is_automated_or_short as _is_automated_or_short,
)


# --- Configuration ---

DEFAULT_DB = Path.home() / ".local/share/opencode/opencode.db"
OUTPUT_DIR = Path.home() / ".aidevops/.agent-workspace/work/session-miner"
SCRIPT_DIR = Path(__file__).resolve().parents[1]
VAULT_HISTORY_HELPER = SCRIPT_DIR / "vault-managed-session-history-helper.sh"

# --- Instruction candidate detection ---
#
# Design: high precision over recall. Better to miss a candidate than to flood
# with false positives. Only flag generalizable patterns, not task-specific
# directions that reference particular files, PRs, or one-off commands.

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

# Patterns that signal persistent/generalizable guidance
INSTRUCTION_SIGNAL_PATTERNS = [
    # Explicit save-to-instructions requests
    r"\badd\s+(this|that)\s+to\s+(AGENTS\.md|build\.txt|the\s+style\s+guide|the\s+instructions?|the\s+rules?)\b",
    r"\bupdate\s+(AGENTS\.md|build\.txt|the\s+style\s+guide|the\s+instructions?|the\s+rules?)\b",
    r"\bremember\s+(this|that)\s+(rule|convention|preference|pattern|going\s+forward)\b",
    # Persistent directive language
    r"\bfrom\s+now\s+on\b",
    r"\bgoing\s+forward\b",
    r"\bin\s+future\s+sessions?\b",
    r"\balways\s+(?:use|do|check|run|make|prefer|ensure|include|add|put|write|format|start|end|begin|avoid|skip|omit)\b",
    r"\bnever\s+(?:use|do|create|make|add|commit|include|put|write|format|start|end|begin|guess|assume|hardcode)\b",
    r"\bdon'?t\s+ever\s+\w+\b",
    # Convention/rule declarations
    r"\bthe\s+(?:rule|convention|standard|pattern|policy|practice)\s+is\b",
    r"\bour\s+(?:rule|convention|standard|pattern|policy|practice)\s+is\b",
    r"\bwe\s+(?:always|never|prefer|use|avoid)\b",
    r"\bprefer\s+\w+\s+over\b",
    r"\buse\s+\w+\s+instead\s+of\b",
]

# Patterns that indicate task-specific (non-generalizable) directions — these
# are strong disqualifiers. If any match, the candidate is suppressed.
TASK_SPECIFIC_DISQUALIFIERS = [
    # References to specific files by path
    r"(?:fix|edit|update|change|revert|delete|remove)\s+(?:the\s+)?(?:file\s+)?['\"]?[\w./\-]+\.\w{1,6}['\"]?",
    # References to specific PRs, issues, commits
    r"\b(?:PR|pull\s+request|issue|commit|branch)\s+#?\d+\b",
    r"\bGH#\d+\b",
    r"\bt\d{3,}\b",  # task IDs like t1876
    # Undo/revert commands (one-off, not persistent)
    r"\b(?:undo|revert|rollback|reset)\s+(?:that|this|the\s+last)\b",
    # References to "this" specific instance without generalizing
    r"\bthis\s+(?:specific|particular|one)\b",
    # Imperative commands about the current task only
    r"\bfor\s+(?:this|the\s+current)\s+(?:task|issue|PR|commit|session)\b",
]

# Compiled versions
_INSTRUCTION_COMPILED = [re.compile(p, re.IGNORECASE) for p in INSTRUCTION_SIGNAL_PATTERNS]
_DISQUALIFIER_COMPILED = [re.compile(p, re.IGNORECASE) for p in TASK_SPECIFIC_DISQUALIFIERS]

# Target file heuristics — map content keywords to likely instruction files.
# All categories now route to .agents/AGENTS.md "Framework Rules" since
# prompts/build.txt was consolidated into AGENTS.md (t2878).
_TARGET_FILE_RULES: list[tuple[re.Pattern, str, str]] = [
    (re.compile(r"\b(?:shell|bash|script|\.sh|shellcheck|function|local\s+var)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "code_style"),
    (re.compile(r"\b(?:AGENTS\.md|agent|subagent|prompt|instruction|build\.txt)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "agent_instructions"),
    (re.compile(r"\b(?:git|commit|branch|PR|worktree|merge|push|pull)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "git_workflow"),
    (re.compile(r"\b(?:style|format|markdown|emoji|tone|concise|verbose)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "style"),
    (re.compile(r"\b(?:security|secret|credential|token|key|password)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "security"),
    (re.compile(r"\b(?:test|lint|quality|verify|check|validate)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "quality"),
    (re.compile(r"\b(?:AGENTS\.md|workflow|process|lifecycle|routine)\b", re.IGNORECASE),
     ".agents/AGENTS.md", "workflow"),
]
_TARGET_FILE_DEFAULT = (".agents/AGENTS.md", "general")


def _infer_target_file(text: str) -> tuple[str, str]:
    """Infer the most likely instruction file and category for a candidate."""
    for pattern, target_file, category in _TARGET_FILE_RULES:
        if pattern.search(text):
            return target_file, category
    return _TARGET_FILE_DEFAULT


def _score_instruction_candidate(text: str) -> float:
    """Score a text for instruction-candidate confidence (0.0–1.0).

    Higher score = more likely to be a generalizable persistent instruction.
    Returns 0.0 if any disqualifier matches (task-specific direction).
    """
    # Hard disqualifiers — task-specific, not generalizable
    for pattern in _DISQUALIFIER_COMPILED:
        if pattern.search(text):
            return 0.0

    # Count signal pattern matches
    signal_count = sum(1 for p in _INSTRUCTION_COMPILED if p.search(text))
    if signal_count == 0:
        return 0.0

    # Boost for explicit save-to-instructions requests (first 2 patterns)
    explicit_save = any(p.search(text) for p in _INSTRUCTION_COMPILED[:2])
    base_score = min(0.5 + (signal_count * 0.15), 0.95)
    if explicit_save:
        base_score = min(base_score + 0.2, 0.99)

    return round(base_score, 2)


def classify_instruction_candidate(text: str) -> Optional[dict[str, Any]]:
    """Classify user text as a potential instruction candidate.

    Returns a dict with confidence and target_file, or None if not a candidate.
    Conservative: only returns results with confidence >= 0.5.
    """
    if not text or len(text) < 20:
        return None

    confidence = _score_instruction_candidate(text)
    if confidence < 0.5:
        return None

    target_file, category = _infer_target_file(text)
    return {
        "confidence": confidence,
        "target_file": target_file,
        "category": category,
    }


def _build_instruction_candidate_query(
    limit: Optional[int], repo_dir: Optional[str] = None, since_ms: Optional[int] = None,
) -> str:
    """Return the SQL query used to scan user messages for instructions."""
    query = """
    SELECT
        s.id as session_id,
        s.title as session_title,
        s.directory as session_dir,
        m.id as message_id,
        m.time_created as msg_time,
        json_extract(m.data, '$.role') as role
    FROM message m
    JOIN session s ON m.session_id = s.id
    WHERE json_extract(m.data, '$.role') = 'user'
    """
    query += repo_scope_clause(repo_dir)
    query += time_scope_clause(since_ms, "m.time_created")
    query += "\n    ORDER BY m.time_created ASC\n    "
    if limit:
        query += f" LIMIT {int(limit) * 10}"
    return query


def _mark_instruction_text_seen(text: str, seen_texts: set[int]) -> bool:
    """Record text dedup state and return True when this text is new."""
    text_hash = hash(text[:200])
    if text_hash in seen_texts:
        return False
    seen_texts.add(text_hash)
    return True


def _build_instruction_candidate_record(
    row: sqlite3.Row, text: str,
) -> Optional[dict[str, Any]]:
    """Build a normalized instruction-candidate record for one message text."""
    classification = classify_instruction_candidate(text)
    if classification is None:
        return None

    explicit_persistence = any(pattern.search(text) for pattern in _INSTRUCTION_COMPILED[:2])
    fingerprint = re.sub(
        r"\b(always|never|prefer|please|should|must|do not|don't|use)\b", "", text.lower(),
    )
    fingerprint = re.sub(r"[^\w\s]", "", fingerprint)
    fingerprint = re.sub(r"\s+", " ", fingerprint).strip()[:200]
    polarity = "negative" if re.search(r"\b(never|avoid|do not|don't|skip)\b", text, re.IGNORECASE) else "positive"
    return {
        "type": "instruction_candidate",
        "session_id": row["session_id"],
        "message_id": row["message_id"],
        "session_title": row["session_title"] or "",
        "session_dir": _sanitize_path(row["session_dir"] or ""),
        "timestamp": row["msg_time"],
        "text": text[:2000],
        "display_text": redact_instruction_candidate_text(text[:2000]),
        "source_hash": hashlib.sha256(text.encode("utf-8")).hexdigest(),
        "fingerprint": fingerprint,
        "polarity": polarity,
        "explicit_persistence": explicit_persistence,
        "confidence": classification["confidence"],
        "target_file": classification["target_file"],
        "category": classification["category"],
    }


def extract_instruction_windows(text: str) -> list[str]:
    """Return atomic local windows eligible for instruction-candidate scoring."""
    windows = []
    for paragraph in re.split(r"\n\s*\n", text):
        for sentence in re.split(r"(?<=[.!?])\s+(?=[A-Z])", paragraph):
            window = sentence.strip()
            if window and not window.startswith((">", "```", "BEGIN PROMPT", "BEGIN INSTRUCTIONS")):
                windows.append(window[:1000])
    return windows


def _extract_message_instruction_candidates(
    conn: sqlite3.Connection, row: sqlite3.Row, seen_texts: set[int],
) -> list[dict[str, Any]]:
    """Extract all instruction candidates from one user message."""
    records: list[dict[str, Any]] = []
    for text in _fetch_text_parts(conn, row["message_id"]):
        if _is_automated_or_short(text):
            continue
        if not _mark_instruction_text_seen(text, seen_texts):
            continue

        for window in extract_instruction_windows(text):
            record = _build_instruction_candidate_record(row, window)
            if record is not None:
                records.append(record)

    return records


def extract_instruction_candidates(
    conn: sqlite3.Connection, limit: Optional[int] = None, repo_dir: Optional[str] = None,
    since_ms: Optional[int] = None,
) -> list[dict]:
    """Extract instruction candidate signals from user messages.

    Identifies user utterances that appear to be persistent rules or conventions
    that should be captured in instruction files (AGENTS.md, build.txt, etc.).

    Conservative detection: high precision over recall. Task-specific directions
    (referencing particular files, PRs, or one-off commands) are filtered out.

    Returns:
        List of instruction candidate records with text, confidence, target_file,
        session context, and category.
    """
    print("Extracting instruction candidates...", file=sys.stderr)

    candidates: list[dict] = []
    seen_texts: set[int] = set()

    query = _build_instruction_candidate_query(limit, repo_dir, since_ms)
    for row in conn.execute(query, extraction_scope_params(repo_dir, since_ms)):
        candidates.extend(
            _extract_message_instruction_candidates(conn, row, seen_texts),
        )
        if limit and len(candidates) >= limit:
            candidates = candidates[:limit]
            break

    print(f"  Found {len(candidates)} instruction candidates", file=sys.stderr)
    return candidates


def connect_db(db_path: Path) -> sqlite3.Connection:
    """Connect to session database read-only."""
    if not db_path.exists():
        print(f"Error: Database not found at {db_path}", file=sys.stderr)
        sys.exit(1)

    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    return conn


def resolve_managed_history_db(db_path: Path) -> Path:
    """Return the Vault-gated OpenCode DB path when managed history is enabled."""
    if not VAULT_HISTORY_HELPER.exists():
        return db_path
    if "AIDEVOPS_VAULT_MANAGED_SESSION_HISTORY" not in __import__("os").environ:
        return db_path
    # The command is a repo-controlled helper path plus literal arguments; no
    # user input reaches the argv vector. Keep the explicit annotation so
    # external Bandit/CodeFactor B603 checks do not block safe Vault gating.
    result = subprocess.run(  # nosec B603
        [str(VAULT_HISTORY_HELPER), "require-read", "opencode"],
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode != 0:
        message = result.stderr.strip() or "VAULT_LOCKED: managed session/history read denied"
        print(message, file=sys.stderr)
        sys.exit(result.returncode)
    return Path(result.stdout.strip())


def write_output(
    data: list[dict], output_dir: Path, fmt: str = "jsonl",
    extraction_metadata: Optional[dict[str, Optional[int]]] = None,
) -> Path:
    """Write extracted data to output files."""
    output_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")

    out_path = output_dir / f"extraction_{timestamp}.jsonl"  # default

    if fmt == "jsonl":
        out_path = output_dir / f"extraction_{timestamp}.jsonl"
        with open(out_path, "w", encoding="utf-8") as f:
            for record in data:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
    elif fmt == "chunks":
        out_path = output_dir / f"chunks_{timestamp}"
        out_path.mkdir(parents=True, exist_ok=True)
        for i, chunk in enumerate(data):
            chunk_path = out_path / f"{chunk.get('chunk_id', f'chunk_{i}')}.json"
            with open(chunk_path, "w", encoding="utf-8") as f:
                json.dump(chunk, f, indent=2, ensure_ascii=False)
        # Also write a manifest
        manifest = {
            "chunk_count": len(data),
            "chunks": [
                {
                    "id": c.get("chunk_id"),
                    "type": c.get("chunk_type"),
                    "category": c.get("category", ""),
                    "records": c.get("record_count", 0),
                }
                for c in data
            ],
            "created": timestamp,
            "extraction_metadata": extraction_metadata or {},
        }
        with open(out_path / "manifest.json", "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2)

    return out_path


def _nonnegative_epoch_ms(value: str) -> int:
    """Parse a nonnegative epoch timestamp, rejecting unsafe silent fallbacks."""
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("--since-ms must be an integer epoch in milliseconds") from error
    if parsed < 0:
        raise argparse.ArgumentTypeError("--since-ms must be a nonnegative epoch in milliseconds")
    return parsed


def _extraction_metadata(
    since_ms: Optional[int], steerage: list[dict], errors: list[dict],
    instruction_candidates: list[dict], git_correlations: Optional[list[dict]],
) -> dict[str, Optional[int]]:
    """Return an additive run watermark without mutating any scheduler state."""
    timestamps = [
        record["timestamp"] for record in steerage + errors + instruction_candidates
        if record.get("timestamp") is not None
    ]
    if git_correlations:
        timestamps.extend(record["session_end"] for record in git_correlations if record.get("session_end") is not None)
    high_water = max(timestamps) if timestamps else None
    return {
        "window_start_ms": since_ms,
        "window_end_ms": high_water,
        "source_high_water_ms": high_water,
    }


def main():
    parser = argparse.ArgumentParser(description="Extract learning signals from coding sessions")
    parser.add_argument("--db", type=Path, default=DEFAULT_DB,
                        help=f"Path to session database (default: {DEFAULT_DB})")
    parser.add_argument("--format", choices=["jsonl", "chunks"], default="chunks",
                        help="Output format (default: chunks)")
    parser.add_argument("--limit", type=int, default=None,
                        help="Limit records extracted per category")
    parser.add_argument("--output", type=Path, default=OUTPUT_DIR,
                        help=f"Output directory (default: {OUTPUT_DIR})")
    parser.add_argument("--no-git", action="store_true",
                        help="Skip git correlation extraction")
    parser.add_argument("--repo-dir", type=str, default=None,
                        help="Only extract sessions whose directory is this repo or a subdirectory")
    parser.add_argument("--since-ms", type=_nonnegative_epoch_ms, default=None,
                        help="Only process records newer than this epoch timestamp in milliseconds")
    args = parser.parse_args()
    args.db = resolve_managed_history_db(args.db)

    print(f"Session Miner — Extracting from {args.db}", file=sys.stderr)
    if not args.db.exists():
        print(f"Error: Database not found at {args.db}", file=sys.stderr)
        sys.exit(1)
    print(f"  DB size: {args.db.stat().st_size / 1024 / 1024:.1f} MB", file=sys.stderr)
    if args.repo_dir:
        print(f"  Repo scope: {args.repo_dir}", file=sys.stderr)
    if args.since_ms is not None:
        print(f"  High-water start: {args.since_ms}", file=sys.stderr)

    conn = connect_db(args.db)

    try:
        # Phase 1a: Extract steerage
        steerage = extract_steerage(conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms)

        # Phase 1b: Extract errors
        errors = extract_errors(conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms)

        # Phase 1c: Aggregate stats
        stats = extract_error_stats(conn, repo_dir=args.repo_dir, since_ms=args.since_ms)

        # Phase 1d: Extract git correlation (unless disabled)
        git_correlations = None
        if not args.no_git:
            git_correlations = extract_git_correlation(
                conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms,
            )

        # Phase 1e: Extract instruction candidates
        instruction_candidates = extract_instruction_candidates(
            conn, limit=args.limit, repo_dir=args.repo_dir, since_ms=args.since_ms,
        )
        extraction_metadata = _extraction_metadata(
            args.since_ms, steerage, errors, instruction_candidates, git_correlations,
        )
        stats["extraction_metadata"] = extraction_metadata

        # Phase 2: Build chunks for model analysis
        if args.format == "chunks":
            chunk_config = ChunkConfig(
                stats=stats,
                git_correlations=git_correlations,
                instruction_candidates=instruction_candidates,
            )
            chunks = build_chunks(steerage, errors, chunk_config)
            out_path = write_output(
                chunks, args.output, fmt="chunks", extraction_metadata=extraction_metadata,
            )
            print(f"\nOutput: {out_path}/", file=sys.stderr)
            print(f"  {len(chunks)} chunks written", file=sys.stderr)
            print(f"  {len(steerage)} steerage signals", file=sys.stderr)
            print(f"  {len(errors)} error sequences", file=sys.stderr)
            print(f"  {len(instruction_candidates)} instruction candidates", file=sys.stderr)
            if git_correlations is not None:
                productive = sum(1 for c in git_correlations if c["commits_count"] > 0)
                print(f"  {len(git_correlations)} git correlations ({productive} productive)", file=sys.stderr)
        else:
            all_records = [{"type": "stats", **stats}] + steerage + errors
            if git_correlations:
                all_records.extend(git_correlations)
            all_records.extend(instruction_candidates)
            out_path = write_output(
                all_records, args.output, fmt="jsonl", extraction_metadata=extraction_metadata,
            )
            print(f"\nOutput: {out_path}", file=sys.stderr)
            print(f"  {len(steerage)} steerage + {len(errors)} errors + {len(instruction_candidates)} instruction candidates", file=sys.stderr)

        # Print summary to stdout
        summary = {
            "steerage_count": len(steerage),
            "error_count": len(errors),
            "instruction_candidates_count": len(instruction_candidates),
            "steerage_categories": dict(
                sorted(
                    defaultdict(int, {
                        cat: sum(1 for s in steerage if any(c["category"] == cat for c in s["classifications"]))
                        for cat in STEERAGE_PATTERNS
                    }).items(),
                    key=lambda x: -x[1],
                )
            ),
            "error_categories": stats.get("error_categories", {}),
            "output": str(out_path),
            "extraction_metadata": extraction_metadata,
        }
        if git_correlations is not None:
            productive = [c for c in git_correlations if c["commits_count"] > 0]
            summary["git_correlation"] = {
                "total_sessions": len(git_correlations),
                "productive_sessions": len(productive),
                "total_commits": sum(c["commits_count"] for c in git_correlations),
                "avg_commits_per_message": round(
                    sum(c["commits_per_message"] for c in productive) / max(len(productive), 1), 3,
                ),
            }
        if instruction_candidates:
            by_target: dict[str, int] = defaultdict(int)
            by_category: dict[str, int] = defaultdict(int)
            for c in instruction_candidates:
                by_target[c["target_file"]] += 1
                by_category[c["category"]] += 1
            summary["instruction_candidates"] = {
                "count": len(instruction_candidates),
                "by_target_file": dict(sorted(by_target.items(), key=lambda x: -x[1])),
                "by_category": dict(sorted(by_category.items(), key=lambda x: -x[1])),
                "avg_confidence": round(
                    sum(c["confidence"] for c in instruction_candidates) / len(instruction_candidates), 2,
                ),
            }
        print(json.dumps(summary, indent=2))

    finally:
        conn.close()


if __name__ == "__main__":
    main()
