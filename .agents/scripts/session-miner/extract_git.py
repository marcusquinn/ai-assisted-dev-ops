#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Git-correlation helpers for session-miner extraction."""

import os
import re
import sqlite3
import subprocess
import sys
from datetime import datetime
from typing import Optional

from extract_shared import extraction_scope_params, repo_scope_clause, sanitize_path, time_scope_clause


def _find_git_root(directory: str) -> Optional[str]:
    """Find the git root for a directory, or None if not a git repo."""
    try:
        result = subprocess.run(
            ["git", "-C", directory, "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return None
    return None


def _parse_commit_lines(raw_output: str) -> list[dict]:
    """Parse ``git log --format=%H|%aI|%s`` output into commit dicts."""
    commits = []
    for line in raw_output.strip().split("\n"):
        if not line:
            continue
        parts = line.split("|", 2)
        if len(parts) < 3:
            continue
        commit_hash, timestamp, subject = parts
        commits.append({
            "hash": commit_hash[:12],
            "timestamp": timestamp,
            "subject": subject[:200],
        })
    return commits


def _resolve_diff_base(repo_path: str, oldest_commit: str) -> str:
    """Return the diff base ref for aggregate diff stats."""
    parent_check = subprocess.run(
        ["git", "-C", repo_path, "rev-parse", "--verify", "--quiet", f"{oldest_commit}^"],
        capture_output=True,
    )
    if parent_check.returncode == 0:
        return f"{oldest_commit}~1"
    return "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def _attach_aggregate_diff_stats(repo_path: str, commits: list[dict]) -> None:
    """Compute aggregate diff stats for a commit range and attach to *commits[0]*."""
    oldest_commit = commits[-1]["hash"]
    newest_commit = commits[0]["hash"]
    stat_result = subprocess.run(
        ["git", "-C", repo_path, "diff", "--shortstat", _resolve_diff_base(repo_path, oldest_commit), newest_commit],
        capture_output=True, text=True, timeout=15,
    )
    if stat_result.returncode != 0 or not stat_result.stdout.strip():
        return

    stat_line = stat_result.stdout.strip()
    files_match = re.search(r"(\d+) files? changed", stat_line)
    insertions_match = re.search(r"(\d+) insertions?", stat_line)
    deletions_match = re.search(r"(\d+) deletions?", stat_line)
    for commit in commits:
        commit["_aggregate"] = True
    commits[0]["diff_stats"] = {
        "files_changed": int(files_match.group(1)) if files_match else 0,
        "insertions": int(insertions_match.group(1)) if insertions_match else 0,
        "deletions": int(deletions_match.group(1)) if deletions_match else 0,
    }


def _git_log_in_window(
    repo_path: str, start_epoch_ms: int, end_epoch_ms: int, buffer_minutes: int = 60,
) -> list[dict]:
    """Query git log for commits within a time window."""
    start_ts = datetime.fromtimestamp(start_epoch_ms / 1000).isoformat()
    end_ts = datetime.fromtimestamp(end_epoch_ms / 1000 + buffer_minutes * 60).isoformat()
    try:
        result = subprocess.run(
            [
                "git", "-C", repo_path, "log",
                f"--after={start_ts}", f"--before={end_ts}",
                "--format=%H|%aI|%s",
            ],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return []

    if result.returncode != 0 or not result.stdout.strip():
        return []

    commits = _parse_commit_lines(result.stdout)
    if not commits:
        return []

    _attach_aggregate_diff_stats(repo_path, commits)
    return commits


def _extract_diff_stats(commits: list[dict]) -> tuple[int, int, int]:
    """Pull aggregate diff stats from the first commit, if present."""
    if not commits or "diff_stats" not in commits[0]:
        return 0, 0, 0
    stats = commits[0]["diff_stats"]
    return stats.get("files_changed", 0), stats.get("insertions", 0), stats.get("deletions", 0)


def _build_correlation_record(row: sqlite3.Row, commits: list[dict]) -> dict:
    """Build a single git-correlation record from a session row and its commits."""
    user_msg_count = row["user_messages"] or 0
    insertions = deletions = files_changed = 0
    if commits:
        files_changed, insertions, deletions = _extract_diff_stats(commits)

    commits_count = len(commits)
    return {
        "type": "git_correlation",
        "session_title": row["session_title"] or "",
        "session_dir": sanitize_path(row["session_dir"] or ""),
        "session_start": row["session_start"],
        "session_end": row["session_end"],
        "duration_minutes": round((row["session_end"] - row["session_start"]) / 1000 / 60, 1),
        "user_messages": user_msg_count,
        "total_messages": row["total_messages"] or 0,
        "commits_count": commits_count,
        "files_changed": files_changed,
        "insertions": insertions,
        "deletions": deletions,
        "commits_per_message": round(commits_count / user_msg_count, 3) if user_msg_count > 0 else 0,
        "lines_per_message": round((insertions + deletions) / user_msg_count, 1) if user_msg_count > 0 else 0,
        "commits": [{"hash": commit["hash"], "subject": commit["subject"]} for commit in commits],
    }


def extract_git_correlation(
    conn: sqlite3.Connection, limit: Optional[int] = None, repo_dir: Optional[str] = None,
    since_ms: Optional[int] = None,
) -> list[dict]:
    """Extract git-commit correlation data for sessions."""
    print("Extracting git correlation data...", file=sys.stderr)

    query = """
    SELECT
        s.id as session_id,
        s.title as session_title,
        s.directory as session_dir,
        s.time_created as session_start,
        s.time_updated as session_end,
        COUNT(DISTINCT m.id) as total_messages,
        SUM(CASE WHEN json_extract(m.data, '$.role') = 'user' THEN 1 ELSE 0 END) as user_messages
    FROM session s
    LEFT JOIN message m ON m.session_id = s.id
    WHERE s.directory IS NOT NULL AND s.directory != ''
    """
    query += repo_scope_clause(repo_dir)
    query += time_scope_clause(since_ms, "s.time_updated")
    query += """
    GROUP BY s.id
    ORDER BY s.time_created DESC
    """
    if limit:
        query += f" LIMIT {int(limit)}"

    git_root_cache: dict[str, Optional[str]] = {}
    correlations = []
    skipped = 0

    for row in conn.execute(query, extraction_scope_params(repo_dir, since_ms)):
        session_dir = row["session_dir"]
        if not session_dir or not os.path.isdir(session_dir):
            skipped += 1
            continue

        git_root = git_root_cache.setdefault(session_dir, _find_git_root(session_dir))
        if not git_root:
            skipped += 1
            continue

        commits = _git_log_in_window(git_root, row["session_start"], row["session_end"])
        correlations.append(_build_correlation_record(row, commits))

    print(
        f"  Found {len(correlations)} sessions with git data "
        f"({skipped} skipped — no git repo or dir missing)",
        file=sys.stderr,
    )
    productive = sum(1 for correlation in correlations if correlation["commits_count"] > 0)
    print(f"  {productive} sessions produced commits", file=sys.stderr)
    return correlations
