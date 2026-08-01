#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomically verify registry ownership while removing a clean worktree."""

from __future__ import annotations

import sqlite3
import subprocess
import sys


def remove_if_owner_contract(arguments: list[str]) -> int:
    """Remove one worktree while its exact registry row is write-locked."""
    if len(arguments) != 10:
        return 1

    (
        db_path,
        worktree_path,
        repository_root,
        git_path,
        expected_branch,
        expected_owner_pid_text,
        expected_owner_session,
        expected_owner_batch,
        expected_task_id,
        expected_created_at,
    ) = arguments
    try:
        expected_owner_pid = int(expected_owner_pid_text)
    except ValueError:
        return 1

    expected_owner = (
        expected_branch,
        expected_owner_pid,
        expected_owner_session,
        expected_owner_batch,
        expected_task_id,
        expected_created_at,
    )
    try:
        connection = sqlite3.connect(db_path, timeout=30, isolation_level=None)
    except sqlite3.Error:
        return 1

    try:
        connection.execute("BEGIN IMMEDIATE")
        observed_owner = connection.execute(
            """SELECT branch, owner_pid, COALESCE(owner_session, ''),
                      COALESCE(owner_batch, ''), COALESCE(task_id, ''),
                      COALESCE(created_at, '')
               FROM worktree_owners WHERE worktree_path = ?""",
            (worktree_path,),
        ).fetchone()
        if observed_owner != expected_owner:
            connection.execute("ROLLBACK")
            return 1
        removal = subprocess.run(
            [git_path, "-C", repository_root, "worktree", "remove", worktree_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=60,
        )
        if removal.returncode != 0:
            connection.execute("ROLLBACK")
            return 1
        deleted = connection.execute(
            """DELETE FROM worktree_owners
               WHERE worktree_path = ? AND branch = ? AND owner_pid = ?
                 AND COALESCE(owner_session, '') = ?
                 AND COALESCE(owner_batch, '') = ?
                 AND COALESCE(task_id, '') = ?
                 AND COALESCE(created_at, '') = ?""",
            (
                worktree_path,
                expected_branch,
                expected_owner_pid,
                expected_owner_session,
                expected_owner_batch,
                expected_task_id,
                expected_created_at,
            ),
        )
        if deleted.rowcount != 1:
            connection.execute("ROLLBACK")
            return 1
        connection.execute("COMMIT")
    except (OSError, sqlite3.Error, subprocess.SubprocessError):
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        return 1
    finally:
        connection.close()
    return 0


if __name__ == "__main__":
    sys.exit(remove_if_owner_contract(sys.argv[1:]))
