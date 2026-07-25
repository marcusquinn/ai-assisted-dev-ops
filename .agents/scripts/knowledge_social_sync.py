#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic social sync scheduling, fenced leases, and reconciliation."""

from __future__ import annotations

import argparse
import json
import sqlite3
import subprocess
import sys
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from _knowledge_social_reconcile import command_reconcile
from _knowledge_social_sync_state import (
    LeaseRequest,
    RunFinish,
    RunStart,
    SyncError,
    acquire_lease,
    begin_run,
    due_connections,
    finish_run,
    last_success,
    now_for_args,
    release_lease,
    retry_is_blocked,
    utc_text,
)
from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_store import (
    SocialStoreError,
    connect,
    migrate,
    validate_opaque,
    validate_root,
)


@dataclass(frozen=True)
class DueWork:
    """One stable connection/stream work item."""

    connection_id: str
    account_id: str
    stream: str


def run_adapter(args: argparse.Namespace, work: DueWork, token: int) -> dict[str, Any]:
    """Invoke the guarded provider adapter without exposing private output."""
    command = [
        sys.executable,
        str(Path(__file__).with_name("knowledge_social_x.py")),
        "--base",
        str(args.base),
        "--alias",
        args.alias,
        "--connection-id",
        work.connection_id,
        "--account-id",
        work.account_id,
        "--stream",
        work.stream,
        "--budget",
        str(args.budget),
        "--fencing-token",
        str(token),
    ]
    for option in ("app", "username", "fixture"):
        value = getattr(args, option)
        if value:
            command.extend((f"--{option}", str(value)))
    completed = subprocess.run(command, check=False, capture_output=True, text=True)
    if completed.returncode != 0:
        raise SyncError("provider adapter failed; inspect private local diagnostics")
    try:
        result = json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise SyncError("provider adapter returned invalid output") from error
    if not isinstance(result, dict):
        raise SyncError("provider adapter returned invalid output")
    return result


def _streams(row: sqlite3.Row) -> tuple[str, ...]:
    try:
        parsed = json.loads(row["enabled_streams"])
    except json.JSONDecodeError as error:
        raise SyncError("stored enabled_streams is invalid") from error
    if not isinstance(parsed, list) or any(not isinstance(item, str) for item in parsed):
        raise SyncError("stored enabled_streams must be an array of text")
    return tuple(sorted(set(parsed)))


def _is_due(
    database: sqlite3.Connection, work: DueWork, now: datetime, cutoff: str
) -> bool:
    previous = last_success(database, work.connection_id, work.stream)
    interval_elapsed = previous is None or previous < cutoff
    return interval_elapsed and not retry_is_blocked(
        database, work.connection_id, work.stream, now
    )


def _finish_adapter_run(
    database: sqlite3.Connection,
    run_id: str,
    work: DueWork,
    result: dict[str, Any],
    completed_at: str,
) -> bool:
    status = str(result.get("status", "failed"))
    successful = status == "complete"
    retry_value = result.get("retry_after")
    finish_run(
        database,
        RunFinish(
            run_id,
            "complete" if successful else status,
            completed_at,
            int(result.get("resources", 0)),
            None if successful else str(result.get("failure_class", status)),
            None if successful or retry_value is None else str(retry_value),
            {"stream": work.stream},
        ),
    )
    return successful


def _execute_work(
    args: argparse.Namespace,
    database: sqlite3.Connection,
    work: DueWork,
    now: datetime,
) -> bool | None:
    lease = LeaseRequest(work.connection_id, args.collector_id, now, args.lease_seconds)
    token = acquire_lease(database, lease)
    if token is None:
        return None
    completed_at = utc_text(now)
    run_id = begin_run(
        database,
        RunStart(work.connection_id, work.stream, "sync", token, completed_at),
    )
    try:
        return _finish_adapter_run(
            database, run_id, work, run_adapter(args, work, token), completed_at
        )
    except Exception:
        finish_run(
            database,
            RunFinish(
                run_id,
                "failed",
                completed_at,
                failure_class="collector",
                diagnostics={"stream": work.stream},
            ),
        )
        return False
    finally:
        release_lease(database, work.connection_id, args.collector_id, token)


def command_sync_due(
    args: argparse.Namespace, database: sqlite3.Connection
) -> dict[str, Any]:
    """Run each due private connection deterministically under one fenced lease."""
    now = now_for_args(args)
    rows, cutoff = due_connections(database, now, args.interval_seconds)
    work_items = [
        DueWork(row["connection_id"], row["remote_account_id"], stream)
        for row in rows
        for stream in _streams(row)
    ]
    due = [work for work in work_items if _is_due(database, work, now, cutoff)]
    outcomes = [_execute_work(args, database, work, now) for work in due] if args.execute else []
    completed = sum(outcome is True for outcome in outcomes)
    failed = sum(outcome is False for outcome in outcomes)
    return {
        "status": "complete" if failed == 0 else "partial",
        "scheduled": len(due),
        "completed": completed,
        "failed": failed,
    }


def parse_args() -> argparse.Namespace:
    """Parse deterministic routine arguments."""
    parser = argparse.ArgumentParser(description=__doc__)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--base", type=Path)
    common.add_argument("--alias", default=DEFAULT_ALIAS)
    common.add_argument("--now", help=argparse.SUPPRESS)
    subparsers = parser.add_subparsers(dest="command", required=True)

    lease = subparsers.add_parser("acquire-lease", parents=[common])
    lease.add_argument("--connection-id", required=True)
    lease.add_argument("--collector-id", required=True)
    lease.add_argument("--lease-seconds", type=int, default=900)

    release = subparsers.add_parser("release-lease", parents=[common])
    release.add_argument("--connection-id", required=True)
    release.add_argument("--collector-id", required=True)
    release.add_argument("--fencing-token", required=True, type=int)

    due = subparsers.add_parser("sync-due", parents=[common])
    due.add_argument("--collector-id", required=True)
    due.add_argument("--lease-seconds", type=int, default=900)
    due.add_argument("--interval-seconds", type=int, default=86400)
    due.add_argument("--budget", type=int, default=10)
    due.add_argument("--app")
    due.add_argument("--username")
    due.add_argument("--execute", action="store_true")
    due.add_argument("--fixture", type=Path, help=argparse.SUPPRESS)

    reconcile = subparsers.add_parser("reconcile", parents=[common])
    reconcile.add_argument("--connection-id", required=True)
    reconcile.add_argument("--stream", required=True)
    reconcile.add_argument("--collector-id", required=True)
    reconcile.add_argument("--lease-seconds", type=int, default=900)
    reconcile.add_argument("--snapshot", type=Path, required=True)
    return parser.parse_args()


def validate_bounds(args: argparse.Namespace) -> None:
    """Reject unsafe or nonsensical routine bounds."""
    for name in ("lease_seconds", "interval_seconds", "budget"):
        value = getattr(args, name, None)
        if value is not None and value < 1:
            raise SyncError(f"--{name.replace('_', '-')} must be positive")
    if getattr(args, "budget", 1) > 1000:
        raise SyncError("--budget must not exceed 1000")


def _lease_command(args: argparse.Namespace, database: sqlite3.Connection) -> dict[str, Any]:
    token = acquire_lease(
        database,
        LeaseRequest(
            validate_opaque(args.connection_id, "connection_id"),
            validate_opaque(args.collector_id, "collector_id"),
            now_for_args(args),
            args.lease_seconds,
        ),
    )
    return {"status": "acquired", "fencing_token": token} if token else {"status": "held"}


def _release_command(args: argparse.Namespace, database: sqlite3.Connection) -> dict[str, str]:
    released = release_lease(
        database,
        validate_opaque(args.connection_id, "connection_id"),
        validate_opaque(args.collector_id, "collector_id"),
        args.fencing_token,
    )
    return {"status": "released" if released else "stale"}


def _dispatch(
    args: argparse.Namespace, root: Path, database: sqlite3.Connection
) -> dict[str, Any]:
    if args.command == "acquire-lease":
        return _lease_command(args, database)
    if args.command == "release-lease":
        return _release_command(args, database)
    validate_opaque(args.collector_id, "collector_id")
    if args.command == "sync-due":
        return command_sync_due(args, database)
    return command_reconcile(args, root, database)


def main() -> int:
    """Run a synchronization control command."""
    args = parse_args()
    try:
        validate_bounds(args)
        base = args.base or Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        args.base = base
        root = validate_root(resolve(base, args.alias, "knowledge.write"))
        database = connect(root)
        try:
            migrate(database)
            result = _dispatch(args, root, database)
        finally:
            database.close()
        print(json.dumps(result, sort_keys=True))
        return 0
    except (
        CatalogError,
        json.JSONDecodeError,
        OSError,
        SocialStoreError,
        sqlite3.Error,
        SyncError,
        ValueError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
