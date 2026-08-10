#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Steerage extraction helpers for session-miner."""

import hashlib
import re
import sqlite3
import sys
from typing import Any, Optional

from extract_shared import (
    extraction_scope_params,
    repo_scope_clause,
    sanitize_path,
    time_scope_clause,
)


STEERAGE_PATTERNS = {
    "correction": [
        r"\bno[,.]?\s+(don'?t|do not|never|stop)\b",
        r"\bthat'?s\s+(wrong|incorrect|not right|not what)\b",
        r"\bactually[,.]?\s",
        r"\binstead[,.]?\s",
        r"\bshould\s+(have|be|use|do)\b",
        r"\bwhy\s+(did you|are you|would you)\b",
    ],
    "preference": [
        r"\b(i\s+)?prefer\b",
        r"\balways\s+(use|do|check|run|make)\b",
        r"\bnever\s+(use|do|create|make|add|commit)\b",
        r"\bdon'?t\s+(ever|always|just)\b",
        r"\buse\s+\w+\s+instead\s+of\b",
    ],
    "guidance": [
        r"\bmake\s+sure\s+(to|that|you)\b",
        r"\bremember\s+(to|that)\b",
        r"\bimportant[:\s]",
        r"\bcritical[:\s]",
        r"\brule[:\s]",
        r"\bconvention[:\s]",
        r"\bstandard[:\s]",
    ],
    "workflow": [
        r"\bbefore\s+(you|doing|making|editing|committing)\b",
        r"\bafter\s+(you|doing|making|editing|committing)\b",
        r"\bfirst[,.]?\s+(check|read|run|verify)\b",
        r"\bthe\s+process\s+is\b",
        r"\bthe\s+workflow\s+is\b",
    ],
    "quality": [
        r"\btest(s|ing)?\s+(first|before|after)\b",
        r"\blint\b",
        r"\bverif(y|ied|ication)\b",
        r"\bclean\s+up\b",
        r"\bself-improvement\b",
        r"\btake\s+every\s+.+\s+opportunity\b",
    ],
}

COMPILED_PATTERNS = {
    category: [re.compile(pattern, re.IGNORECASE) for pattern in patterns]
    for category, patterns in STEERAGE_PATTERNS.items()
}

_AUTOMATED_PREFIXES = (
    "/full-loop",
    '"You are the supervisor',
    "Continue if you have next steps",
    "Review the following potential duplicate",
    "Analyze the changes made since",
    "<file>",
    "diff --git",
)
_QUOTED_PAYLOAD_PREFIXES = (">", "```", "BEGIN PROMPT", "BEGIN INSTRUCTIONS")
_DIRECTIVE_CONTEXT = re.compile(
    r"\b(always|never|please|must|should|remember|make sure|before|after|first|do not|don't)\b"
    r"|^(run|use|avoid|skip|lint|test|verify)\b",
    re.IGNORECASE,
)


def is_automated_or_short(text: Optional[str]) -> bool:
    """Return True if *text* should be skipped (None, too short, or templated)."""
    if not text or len(text) < 20:
        return True
    stripped = text.lstrip()
    return any(stripped.startswith(prefix) for prefix in _AUTOMATED_PREFIXES + _QUOTED_PAYLOAD_PREFIXES)


def _sentence_windows(text: str) -> list[str]:
    """Return bounded, human-authored sentence or paragraph windows from *text*."""
    windows: list[str] = []
    for paragraph in re.split(r"\n\s*\n", text):
        paragraph = paragraph.strip()
        if not paragraph or paragraph.startswith(_QUOTED_PAYLOAD_PREFIXES):
            continue
        sentences = re.split(r"(?<=[.!?])\s+(?=[A-Z])", paragraph)
        windows.extend(sentence.strip() for sentence in sentences if sentence.strip())
    return windows


def extract_guidance_windows(text: str) -> list[dict[str, Any]]:
    """Return classified atomic guidance windows rather than a whole user turn."""
    if is_automated_or_short(text):
        return []

    windows: list[dict[str, Any]] = []
    for window in _sentence_windows(text):
        classifications = classify_steerage(window)
        # Broad quality keywords such as "lint" are useful only in a directive,
        # otherwise long explanatory turns would become false steerage signals.
        is_correction = any(item["category"] == "correction" for item in classifications)
        if classifications and (is_correction or _DIRECTIVE_CONTEXT.search(window)):
            windows.append({"text": window[:1000], "classifications": classifications})
    return windows


def fetch_text_parts(conn: sqlite3.Connection, message_id: str) -> list[str]:
    """Return all text-part strings for a given message."""
    rows = conn.execute(
        """SELECT json_extract(data, '$.text') as text
           FROM part
           WHERE message_id = ? AND json_extract(data, '$.type') = 'text'""",
        (message_id,),
    ).fetchall()
    return [row["text"] for row in rows if row["text"]]


def _fetch_preceding_assistant_text(
    conn: sqlite3.Connection, session_id: str, before_time: Any,
) -> str:
    """Return the preceding assistant text (up to 500 chars), or ``""``."""
    previous = conn.execute(
        """SELECT json_extract(p.data, '$.text') as text
           FROM part p
           JOIN message m ON p.message_id = m.id
           WHERE m.session_id = ?
             AND m.time_created < ?
             AND json_extract(m.data, '$.role') = 'assistant'
             AND json_extract(p.data, '$.type') = 'text'
           ORDER BY m.time_created DESC
           LIMIT 1""",
        (session_id, before_time),
    ).fetchone()
    if not previous or not previous["text"]:
        return ""
    return previous["text"][:500]


def classify_steerage(text: str) -> list[dict[str, Any]]:
    """Classify user text into steerage categories with matched patterns."""
    if not text or len(text) < 15:
        return []

    matches = []
    for category, patterns in COMPILED_PATTERNS.items():
        for pattern in patterns:
            match = pattern.search(text)
            if match is None:
                continue
            matches.append({
                "category": category,
                "matched": match.group(0),
                "position": match.start(),
            })
            break
    return matches


def _build_steerage_record(
    conn: sqlite3.Connection, row: sqlite3.Row, window: dict[str, Any], source_text: str,
) -> dict:
    """Build a provenance-aware steerage record for one atomic guidance window."""
    window_text = window["text"]
    return {
        "type": "steerage",
        "session_id": row["session_id"],
        "message_id": row["message_id"],
        "session_title": row["session_title"] or "",
        "session_dir": sanitize_path(row["session_dir"] or ""),
        "timestamp": row["msg_time"],
        "user_text": window_text,
        "source_hash": hashlib.sha256(source_text.encode("utf-8")).hexdigest(),
        "classifications": window["classifications"],
        "preceding_context": _fetch_preceding_assistant_text(conn, row["session_id"], row["msg_time"]),
    }


def _collect_steerage_from_message(
    conn: sqlite3.Connection, row: sqlite3.Row, seen_texts: set[int],
) -> list[dict]:
    """Return steerage records found in a single user message's text parts."""
    records = []
    for text in fetch_text_parts(conn, row["message_id"]):
        if is_automated_or_short(text):
            continue

        text_hash = hash(text[:200])
        if text_hash in seen_texts:
            continue
        seen_texts.add(text_hash)

        for window in extract_guidance_windows(text):
            records.append(_build_steerage_record(conn, row, window, text))
    return records


def extract_steerage(
    conn: sqlite3.Connection, limit: Optional[int] = None, repo_dir: Optional[str] = None,
    since_ms: Optional[int] = None,
) -> list[dict]:
    """Extract user steerage signals from sessions."""
    print("Extracting user steerage signals...", file=sys.stderr)

    query = """
    SELECT
        s.id as session_id,
        s.title as session_title,
        s.directory as session_dir,
        m.id as message_id,
        m.time_created as msg_time,
        json_extract(m.data, '$.role') as role,
        json_extract(m.data, '$.modelID') as model
    FROM message m
    JOIN session s ON m.session_id = s.id
    WHERE json_extract(m.data, '$.role') = 'user'
    """
    query += repo_scope_clause(repo_dir)
    query += time_scope_clause(since_ms, "m.time_created")
    query += "\n    ORDER BY m.time_created ASC\n    "
    if limit:
        query += f" LIMIT {int(limit) * 10}"

    records: list[dict] = []
    seen_texts: set[int] = set()
    for row in conn.execute(query, extraction_scope_params(repo_dir, since_ms)):
        records.extend(_collect_steerage_from_message(conn, row, seen_texts))
        if limit and len(records) >= limit:
            records = records[:limit]
            break

    print(f"  Found {len(records)} steerage signals", file=sys.stderr)
    return records
