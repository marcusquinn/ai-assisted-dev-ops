#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Error extraction helpers for session-miner."""

import json
import re
import sqlite3
import sys
from collections import defaultdict
from typing import Any, Optional

from extract_shared import (
    extraction_scope_params,
    repo_scope_clause,
    sanitize_path,
    summarize_tool_input,
    time_scope_clause,
)


ERROR_CATEGORIES = {
    "command_policy": re.compile(r"BLOCKED\s+by\s+shared\s+command\s+policy", re.IGNORECASE),
    "workdir_not_found": re.compile(r"NotFound:\s*FileSystem\.access\s*\(", re.IGNORECASE),
    "file_not_found": re.compile(r"(file not found|no such file|ENOENT)", re.IGNORECASE),
    "edit_stale_read": re.compile(r"modified since.*(last read|was read)", re.IGNORECASE),
    "edit_mismatch": re.compile(r"(oldString|could not find).*in (the )?file", re.IGNORECASE),
    "edit_multiple": re.compile(r"(multiple matches|found multiple)", re.IGNORECASE),
    "permission": re.compile(r"permission denied", re.IGNORECASE),
    "timeout": re.compile(r"(timeout|timed out)", re.IGNORECASE),
    "exit_code": re.compile(r"(exit code|exited with|ShellError)", re.IGNORECASE),
    "not_read_first": re.compile(r"must.*read.*before|without.*prior.*read", re.IGNORECASE),
}


def classify_error(error_text: str) -> str:
    """Classify a tool error into a category."""
    if not error_text:
        return "unknown"

    for category, pattern in ERROR_CATEGORIES.items():
        if pattern.search(error_text):
            return category

    return "other"


def _parse_json_safe(raw: Any) -> dict:
    """Parse a JSON string or pass through a dict; return ``{}`` on failure."""
    if not raw:
        return {}
    if isinstance(raw, dict):
        return raw
    try:
        return json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return {}


def _find_recovery(
    conn: sqlite3.Connection, session_id: str, after_time: Any, tool_name: str,
) -> Optional[dict]:
    """Look at the next 3 tool calls; return recovery info if the same tool succeeded."""
    next_tools = conn.execute(
        """SELECT
            json_extract(data, '$.tool') as tool,
            json_extract(data, '$.state.status') as status,
            json_extract(data, '$.state.input') as input_json
           FROM part
           WHERE session_id = ?
             AND time_created > ?
             AND json_extract(data, '$.type') = 'tool'
           ORDER BY time_created ASC
           LIMIT 3""",
        (session_id, after_time),
    ).fetchall()

    for next_tool in next_tools:
        if next_tool["tool"] != tool_name or next_tool["status"] != "completed":
            continue
        recovery_input = _parse_json_safe(next_tool["input_json"])
        return {
            "tool": next_tool["tool"],
            "approach": summarize_tool_input(next_tool["tool"], recovery_input),
        }
    return None


def _find_user_response_after(
    conn: sqlite3.Connection, session_id: str, after_time: Any,
) -> Optional[str]:
    """Return the first user text message after *after_time*, or ``None``."""
    user_after = conn.execute(
        """SELECT json_extract(p2.data, '$.text') as text
           FROM part p2
           JOIN message m ON p2.message_id = m.id
           WHERE m.session_id = ?
             AND m.time_created > ?
             AND json_extract(m.data, '$.role') = 'user'
             AND json_extract(p2.data, '$.type') = 'text'
           ORDER BY m.time_created ASC
           LIMIT 1""",
        (session_id, after_time),
    ).fetchone()
    if not user_after or not user_after["text"]:
        return None
    return user_after["text"][:500]


def extract_errors(
    conn: sqlite3.Connection, limit: Optional[int] = None, repo_dir: Optional[str] = None,
    since_ms: Optional[int] = None,
) -> list[dict]:
    """Extract tool error sequences with surrounding context."""
    print("Extracting error sequences...", file=sys.stderr)

    query = """
    SELECT
        p.id as part_id,
        p.session_id,
        p.message_id,
        p.time_created,
        json_extract(p.data, '$.tool') as tool_name,
        json_extract(p.data, '$.state.error') as error_text,
        json_extract(p.data, '$.state.input') as tool_input_json,
        json_extract(m.data, '$.modelID') as model_id,
        s.title as session_title,
        s.directory as session_dir
    FROM part p
    JOIN message m ON p.message_id = m.id
    JOIN session s ON p.session_id = s.id
    WHERE json_extract(p.data, '$.type') = 'tool'
      AND json_extract(p.data, '$.state.status') = 'error'
    """
    query += repo_scope_clause(repo_dir)
    query += time_scope_clause(since_ms, "p.time_created")
    query += "\n    ORDER BY p.time_created DESC\n    "
    if limit:
        query += f" LIMIT {int(limit)}"

    records = []
    for row in conn.execute(query, extraction_scope_params(repo_dir, since_ms)):
        error_text = row["error_text"] or ""
        tool_name = row["tool_name"] or "unknown"
        tool_input = _parse_json_safe(row["tool_input_json"])
        records.append({
            "type": "error",
            "session_title": row["session_title"] or "",
            "session_dir": sanitize_path(row["session_dir"] or ""),
            "timestamp": row["time_created"],
            "model": row["model_id"] or "unknown",
            "tool": tool_name,
            "error_category": classify_error(error_text),
            "error_text": error_text[:500],
            "tool_input_summary": summarize_tool_input(tool_name, tool_input),
            "recovery": _find_recovery(conn, row["session_id"], row["time_created"], tool_name),
            "user_response": _find_user_response_after(conn, row["session_id"], row["time_created"]),
        })

    print(f"  Found {len(records)} error sequences", file=sys.stderr)
    return records


def extract_error_stats(
    conn: sqlite3.Connection, repo_dir: Optional[str] = None, since_ms: Optional[int] = None,
) -> dict:
    """Extract aggregate error statistics for the summary."""
    stats = {}

    params = extraction_scope_params(repo_dir, since_ms)
    tool_rows = conn.execute("""
        SELECT
            json_extract(p.data, '$.tool') as tool,
            COUNT(*) as total,
            SUM(CASE WHEN json_extract(p.data, '$.state.status') = 'error' THEN 1 ELSE 0 END) as errors
        FROM part p
        JOIN session s ON p.session_id = s.id
        WHERE json_extract(p.data, '$.type') = 'tool'
    """ + repo_scope_clause(repo_dir) + time_scope_clause(since_ms, "p.time_created") + """
        GROUP BY tool
        ORDER BY total DESC
    """, params).fetchall()
    stats["tool_error_rates"] = {
        row["tool"]: {
            "total": row["total"],
            "errors": row["errors"],
            "rate": round(row["errors"] / max(row["total"], 1), 4),
        }
        for row in tool_rows
        if row["tool"]
    }

    error_rows = conn.execute("""
        SELECT json_extract(p.data, '$.state.error') as err
        FROM part p
        JOIN session s ON p.session_id = s.id
        WHERE json_extract(p.data, '$.type') = 'tool'
          AND json_extract(p.data, '$.state.status') = 'error'
    """ + repo_scope_clause(repo_dir) + time_scope_clause(since_ms, "p.time_created"), params).fetchall()
    category_counts = defaultdict(int)
    for row in error_rows:
        category_counts[classify_error(row["err"] or "")] += 1
    stats["error_categories"] = dict(sorted(category_counts.items(), key=lambda item: -item[1]))

    model_rows = conn.execute("""
        SELECT json_extract(m.data, '$.modelID') as model, COUNT(*) as cnt
        FROM message m
        JOIN session s ON m.session_id = s.id
        WHERE json_extract(m.data, '$.role') = 'assistant'
    """ + repo_scope_clause(repo_dir) + time_scope_clause(since_ms, "m.time_created") + """
        GROUP BY model
        ORDER BY cnt DESC
        LIMIT 10
    """, params).fetchall()
    stats["model_usage"] = {row["model"]: row["cnt"] for row in model_rows if row["model"]}

    session_row = conn.execute("""
        SELECT COUNT(*) as cnt,
               MIN(time_created) as earliest,
               MAX(time_created) as latest
        FROM session s
        WHERE 1 = 1
    """ + repo_scope_clause(repo_dir) + time_scope_clause(since_ms, "s.time_updated"), params).fetchone()
    stats["sessions"] = {
        "total": session_row["cnt"],
        "earliest": session_row["earliest"],
        "latest": session_row["latest"],
    }
    return stats
