#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Atomically verify registry ownership while removing a clean worktree."""

from __future__ import annotations

import sqlite3
import subprocess
import sys


class OwnerContractRemovalError(Exception):
    """The exact registry contract does not authorize worktree removal."""


def remove_if_owner_contract(arguments: list[str]) -> int:
    """Remove one worktree while its exact registry row is write-locked."""
    if len(arguments) != 11:
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
        expected_process_start,
    ) = arguments
    connection = None
    try:
        expected_owner_pid = int(expected_owner_pid_text)
        expected_owner = (
            expected_branch,
            expected_owner_pid,
            expected_owner_session,
            expected_owner_batch,
            expected_task_id,
            expected_created_at,
            expected_process_start,
        )
        connection = sqlite3.connect(db_path, timeout=30, isolation_level=None)
        connection.execute("BEGIN IMMEDIATE")
        observed_owner = connection.execute(
            """SELECT branch, owner_pid, COALESCE(owner_session, ''),
                      COALESCE(owner_batch, ''), COALESCE(task_id, ''),
                      COALESCE(created_at, ''), COALESCE(owner_process_start, '')
               FROM worktree_owners WHERE worktree_path = ?""",
            (worktree_path,),
        ).fetchone()
        if observed_owner != expected_owner:
            raise OwnerContractRemovalError
        # The caller command-resolves git and validates both filesystem paths;
        # argv remains structured and never enters a command shell.
        removal = subprocess.run(  # nosec B603
            [git_path, "-C", repository_root, "worktree", "remove", worktree_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=60,
        )
        if removal.returncode != 0:
            raise OwnerContractRemovalError
        deleted = connection.execute(
            """DELETE FROM worktree_owners
               WHERE worktree_path = ? AND branch = ? AND owner_pid = ?
                 AND COALESCE(owner_session, '') = ?
                 AND COALESCE(owner_batch, '') = ?
                  AND COALESCE(task_id, '') = ?
                  AND COALESCE(created_at, '') = ?
                  AND COALESCE(owner_process_start, '') = ?""",
            (
                worktree_path,
                expected_branch,
                expected_owner_pid,
                expected_owner_session,
                expected_owner_batch,
                expected_task_id,
                expected_created_at,
                expected_process_start,
            ),
        )
        if deleted.rowcount != 1:
            raise OwnerContractRemovalError
        connection.execute("COMMIT")
    except (
        ValueError,
        OSError,
        OwnerContractRemovalError,
        sqlite3.Error,
        subprocess.SubprocessError,
    ):
        if connection is not None and connection.in_transaction:
            try:
                connection.execute("ROLLBACK")
            except sqlite3.Error:
                pass
        return 1
    finally:
        if connection is not None:
            connection.close()
    return 0


if __name__ == "__main__":
    sys.exit(remove_if_owner_contract(sys.argv[1:]))
