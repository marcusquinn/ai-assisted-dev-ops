#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Deterministic social sync scheduling, fenced leases, and reconciliation."""

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import uuid
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError, validate_private_file
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import (
    SocialStoreError,
    connect,
    migrate,
    validate_opaque,
    validate_root,
    write_raw_batch,
)


class SyncError(RuntimeError):
    """Raised when deterministic synchronization cannot proceed safely."""


def utc_text(value: datetime) -> str:
    """Return a canonical UTC timestamp."""
    return value.astimezone(UTC).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_time(value: str) -> datetime:
    """Parse a canonical provider or local timestamp."""
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise SyncError("timestamp must be ISO-8601") from error
    if parsed.tzinfo is None:
        raise SyncError("timestamp must include a timezone")
    return parsed.astimezone(UTC)


def now_for_args(args: argparse.Namespace) -> datetime:
    """Resolve the clock, allowing deterministic clocks only in tests."""
    if args.now:
        if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
            raise SyncError("--now is available only in the test harness")
        return parse_time(args.now)
    return datetime.now(UTC)


def acquire_lease(
    database: sqlite3.Connection,
    connection_id: str,
    holder_id: str,
    now: datetime,
    lease_seconds: int,
) -> int | None:
    """Acquire or renew one connection lease and return its fencing token."""
    current_text = utc_text(now)
    lease_until = utc_text(now + timedelta(seconds=lease_seconds))
    database.execute("BEGIN IMMEDIATE")
    try:
        row = database.execute(
            "SELECT holder_id,fencing_token,lease_until FROM collector_leases "
            "WHERE connection_id=?",
            (connection_id,),
        ).fetchone()
        if row is not None and parse_time(row["lease_until"]) > now:
            if row["holder_id"] != holder_id:
                database.execute("ROLLBACK")
                return None
            token = int(row["fencing_token"])
        else:
            token = 1 if row is None else int(row["fencing_token"]) + 1
            database.execute(
                """UPDATE sync_runs SET status='failed',failure_class='interrupted',
                   completed_at=? WHERE connection_id=? AND status='running'""",
                (current_text, connection_id),
            )
        database.execute(
            """INSERT INTO collector_leases(
               connection_id,holder_id,fencing_token,lease_until,acquired_at,updated_at)
               VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id) DO UPDATE SET
               holder_id=excluded.holder_id,fencing_token=excluded.fencing_token,
               lease_until=excluded.lease_until,acquired_at=excluded.acquired_at,
               updated_at=excluded.updated_at""",
            (connection_id, holder_id, token, lease_until, current_text, current_text),
        )
        database.execute("COMMIT")
        return token
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        raise


def release_lease(
    database: sqlite3.Connection, connection_id: str, holder_id: str, token: int
) -> bool:
    """Release only the exact lease generation owned by this collector."""
    deleted = database.execute(
        "DELETE FROM collector_leases WHERE connection_id=? AND holder_id=? "
        "AND fencing_token=?",
        (connection_id, holder_id, token),
    ).rowcount
    return deleted == 1


def begin_run(
    database: sqlite3.Connection,
    connection_id: str,
    stream: str,
    run_type: str,
    token: int,
    started_at: str,
) -> str:
    """Persist a running receipt before external work begins."""
    run_id = uuid.uuid4().hex
    database.execute(
        """INSERT INTO sync_runs(
           run_id,connection_id,status,fencing_token,diagnostics,stream,run_type,started_at)
           VALUES(?,?,?,?,?,?,?,?)""",
        (
            run_id,
            connection_id,
            "running",
            str(token),
            canonical_json({"stream": stream}),
            stream,
            run_type,
            started_at,
        ),
    )
    return run_id


def finish_run(
    database: sqlite3.Connection,
    run_id: str,
    status: str,
    completed_at: str,
    resource_count: int = 0,
    failure_class: str | None = None,
    retry_after: str | None = None,
    diagnostics: dict[str, Any] | None = None,
) -> None:
    """Finalize a durable privacy-safe run receipt."""
    updated = database.execute(
        """UPDATE sync_runs SET status=?,resource_count=?,failure_class=?,retry_after=?,
           diagnostics=?,completed_at=? WHERE run_id=? AND status='running'""",
        (
            status,
            resource_count,
            failure_class,
            retry_after,
            canonical_json(diagnostics or {}),
            completed_at,
            run_id,
        ),
    ).rowcount
    if updated != 1:
        raise SyncError("run receipt is not in the running state")


def due_connections(
    database: sqlite3.Connection, now: datetime, interval_seconds: int
) -> tuple[list[sqlite3.Row], str]:
    """Return due connection/stream pairs in a stable order."""
    cutoff = utc_text(now - timedelta(seconds=interval_seconds))
    return database.execute(
        """SELECT c.connection_id,c.remote_account_id,c.enabled_streams,
                  c.policy_json,c.auth_profile_ref
           FROM connections c ORDER BY c.connection_id"""
    ).fetchall(), cutoff


def last_success(
    database: sqlite3.Connection, connection_id: str, stream: str
) -> str | None:
    """Return the last terminal successful routine receipt."""
    row = database.execute(
        """SELECT completed_at FROM sync_runs
           WHERE connection_id=? AND stream=? AND status='complete'
             AND completed_at IS NOT NULL ORDER BY completed_at DESC LIMIT 1""",
        (connection_id, stream),
    ).fetchone()
    return None if row is None else str(row["completed_at"])


def retry_is_blocked(
    database: sqlite3.Connection,
    connection_id: str,
    stream: str,
    now: datetime,
) -> bool:
    """Honor the latest provider reset instead of creating a retry storm."""
    row = database.execute(
        """SELECT retry_after FROM sync_runs
           WHERE connection_id=? AND stream=? AND retry_after IS NOT NULL
           ORDER BY completed_at DESC,rowid DESC LIMIT 1""",
        (connection_id, stream),
    ).fetchone()
    if row is None:
        return False
    value = str(row["retry_after"])
    try:
        reset = datetime.fromtimestamp(int(value), UTC)
    except ValueError:
        reset = parse_time(value)
    return reset > now


def run_adapter(
    args: argparse.Namespace,
    connection_id: str,
    account_id: str,
    stream: str,
    token: int,
) -> dict[str, Any]:
    """Invoke the guarded provider adapter without passing private values to output."""
    command = [
        sys.executable,
        str(Path(__file__).with_name("knowledge_social_x.py")),
        "--base",
        str(args.base),
        "--alias",
        args.alias,
        "--connection-id",
        connection_id,
        "--account-id",
        account_id,
        "--stream",
        stream,
        "--budget",
        str(args.budget),
        "--fencing-token",
        str(token),
    ]
    if args.app:
        command.extend(("--app", args.app))
    if args.username:
        command.extend(("--username", args.username))
    if args.fixture:
        command.extend(("--fixture", str(args.fixture)))
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


def command_sync_due(
    args: argparse.Namespace, root: Path, database: sqlite3.Connection
) -> dict[str, Any]:
    """Run each due private connection deterministically under one fenced lease."""
    now = now_for_args(args)
    rows, cutoff = due_connections(database, now, args.interval_seconds)
    scheduled = 0
    completed = 0
    failed = 0
    for row in rows:
        try:
            streams = json.loads(row["enabled_streams"])
        except json.JSONDecodeError as error:
            raise SyncError("stored enabled_streams is invalid") from error
        if not isinstance(streams, list) or any(not isinstance(item, str) for item in streams):
            raise SyncError("stored enabled_streams must be an array of text")
        for stream in sorted(set(streams)):
            previous = last_success(database, row["connection_id"], stream)
            if (previous is not None and previous >= cutoff) or retry_is_blocked(
                database, row["connection_id"], stream, now
            ):
                continue
            scheduled += 1
            if not args.execute:
                continue
            token = acquire_lease(
                database,
                row["connection_id"],
                args.collector_id,
                now,
                args.lease_seconds,
            )
            if token is None:
                continue
            run_id = begin_run(
                database,
                row["connection_id"],
                stream,
                "sync",
                token,
                utc_text(now),
            )
            try:
                result = run_adapter(
                    args,
                    row["connection_id"],
                    row["remote_account_id"],
                    stream,
                    token,
                )
                status = str(result.get("status", "failed"))
                successful = status == "complete"
                retry_value = result.get("retry_after")
                finish_run(
                    database,
                    run_id,
                    "complete" if successful else status,
                    utc_text(now),
                    int(result.get("resources", 0)),
                    None if successful else str(result.get("failure_class", status)),
                    None if successful or retry_value is None else str(retry_value),
                    {"stream": stream},
                )
                completed += int(successful)
                failed += int(not successful)
            except Exception:
                finish_run(
                    database,
                    run_id,
                    "failed",
                    utc_text(now),
                    failure_class="collector",
                    diagnostics={"stream": stream},
                )
                failed += 1
            finally:
                release_lease(database, row["connection_id"], args.collector_id, token)
    return {
        "status": "complete" if failed == 0 else "partial",
        "scheduled": scheduled,
        "completed": completed,
        "failed": failed,
    }


def snapshot_ids(path: Path) -> tuple[str, str, str, list[str], dict[str, Any]]:
    """Read a complete provider reconciliation snapshot."""
    try:
        validate_private_file(path, "reconciliation snapshot", repair=False)
    except CatalogError as error:
        raise SyncError(str(error)) from error
    payload = json.loads(path.read_text(encoding="utf-8"))
    reject_credentials(payload)
    if not isinstance(payload, dict) or payload.get("complete") is not True:
        raise SyncError("reconciliation requires an explicitly complete snapshot")
    provider = payload.get("provider")
    observed_at = payload.get("observed_at")
    object_type = payload.get("object_type", "post")
    remote_ids = payload.get("remote_ids")
    if not all(isinstance(value, str) for value in (provider, observed_at, object_type)):
        raise SyncError("snapshot metadata must be text")
    parse_time(observed_at)
    if not isinstance(remote_ids, list) or any(not isinstance(item, str) for item in remote_ids):
        raise SyncError("snapshot remote_ids must be an array of text")
    return provider, observed_at, object_type, sorted(set(remote_ids)), payload


def command_reconcile(
    args: argparse.Namespace, root: Path, database: sqlite3.Connection
) -> dict[str, Any]:
    """Mark provider-confirmed presence or absence without destructive purge."""
    provider, observed_at, object_type, remote_ids, payload = snapshot_ids(args.snapshot)
    connection_id = validate_opaque(args.connection_id, "connection_id")
    stream = args.stream
    token = acquire_lease(
        database,
        connection_id,
        args.collector_id,
        now_for_args(args),
        args.lease_seconds,
    )
    if token is None:
        return {"status": "lease_held", "present": 0, "missing": 0}
    run_id = begin_run(database, connection_id, stream, "reconcile", token, observed_at)
    try:
        known = {
            str(row[0])
            for row in database.execute(
                """SELECT DISTINCT o.remote_id FROM objects o
                   JOIN fetch_batches b ON b.batch_id=o.batch_id
                   WHERE b.connection_id=? AND b.stream=? AND o.provider=?
                     AND o.object_type=?""",
                (connection_id, stream, provider, object_type),
            )
        }
        present = known.intersection(remote_ids)
        missing = known.difference(remote_ids)
        database.execute("BEGIN IMMEDIATE")
        evidence = canonical_json(
            {
                "provider": provider,
                "connection_id": connection_id,
                "stream": stream,
                "observed_at": observed_at,
                "snapshot": payload,
            }
        ).encode("utf-8")
        batch_id, blob_ref = write_raw_batch(root, provider, connection_id, evidence)
        database.execute(
            """INSERT INTO fetch_batches(
               batch_id,provider,connection_id,stream,response_hash,blob_ref,
               resource_count,budget_units,started_at,completed_at,terminal_status)
               VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(batch_id) DO NOTHING""",
            (
                batch_id,
                provider,
                connection_id,
                stream,
                batch_id,
                blob_ref,
                len(remote_ids),
                0,
                observed_at,
                observed_at,
                "reconciliation",
            ),
        )
        for remote_id in sorted(known):
            database.execute(
                """INSERT INTO reconciliation_observations(
                   provider,connection_id,stream,object_type,remote_id,state,observed_at,run_id)
                   VALUES(?,?,?,?,?,?,?,?) ON CONFLICT(
                   provider,connection_id,stream,object_type,remote_id) DO UPDATE SET
                   state=excluded.state,observed_at=excluded.observed_at,run_id=excluded.run_id""",
                (
                    provider,
                    connection_id,
                    stream,
                    object_type,
                    remote_id,
                    "present" if remote_id in present else "missing",
                    observed_at,
                    run_id,
                ),
            )
        finish_run(
            database,
            run_id,
            "complete",
            observed_at,
            len(known),
            diagnostics={"missing": len(missing), "present": len(present), "stream": stream},
        )
        database.execute("COMMIT")
        return {"status": "complete", "present": len(present), "missing": len(missing)}
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        finish_run(
            database,
            run_id,
            "failed",
            utc_text(datetime.now(UTC)),
            failure_class="reconciliation",
            diagnostics={"stream": stream},
        )
        raise
    finally:
        release_lease(database, connection_id, args.collector_id, token)


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
            if args.command == "acquire-lease":
                token = acquire_lease(
                    database,
                    validate_opaque(args.connection_id, "connection_id"),
                    validate_opaque(args.collector_id, "collector_id"),
                    now_for_args(args),
                    args.lease_seconds,
                )
                result = {"status": "acquired", "fencing_token": token} if token else {"status": "held"}
            elif args.command == "release-lease":
                released = release_lease(
                    database,
                    validate_opaque(args.connection_id, "connection_id"),
                    validate_opaque(args.collector_id, "collector_id"),
                    args.fencing_token,
                )
                result = {"status": "released" if released else "stale"}
            elif args.command == "sync-due":
                validate_opaque(args.collector_id, "collector_id")
                result = command_sync_due(args, root, database)
            else:
                validate_opaque(args.collector_id, "collector_id")
                result = command_reconcile(args, root, database)
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
