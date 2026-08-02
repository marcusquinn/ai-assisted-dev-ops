#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Plan, execute, and report deterministic knowledge collector freshness."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

from _knowledge_collector_model import (  # noqa: E402
    CONNECTORS,
    SCHEMA,
    Connection,
    _connection,
    _record,
    due_at,
    load_config,
    load_state,
)
from _knowledge_collector_health import _health, plan  # noqa: E402
from _knowledge_collector_outcome import _apply_receipt, _record_failure  # noqa: E402
from _knowledge_collector_runtime import (  # noqa: E402
    CollectorInterrupted,
    CollectorScheduleError,
    _receipt,
    _run_bounded,
)

DEFAULT_CONFIG = Path.home() / ".config" / "aidevops" / "knowledge-collectors.json"
DEFAULT_STATE = (
    Path.home()
    / ".aidevops"
    / ".agent-workspace"
    / "knowledge"
    / "collector-health.json"
)


def build_command(connection: Connection) -> list[str]:
    """Build one exact argv vector from the fixed connector allowlist."""
    prefix = CONNECTORS[connection.connector_id]
    entrypoint = prefix[0]
    if not entrypoint.is_file() or entrypoint.is_symlink():
        raise CollectorScheduleError("allowlisted collector entrypoint is unavailable")
    return [str(entrypoint), *prefix[1:], *connection.arguments]


def run_process(connection: Connection, command: list[str]) -> subprocess.CompletedProcess[str]:
    """Execute one bounded collector without a shell or inherited content output."""
    environment = os.environ.copy()
    environment["AIDEVOPS_COLLECTOR_RECEIPT"] = "1"
    return _run_bounded(
        command, connection.working_directory, environment, connection.timeout_seconds
    )


def _run_projection(connection: Connection, timeout: int) -> str:
    if connection.projection_root is None:
        return "not-needed"
    commands = (
        [
            str(SCRIPT_DIR / "document-enrich-helper.sh"),
            "tick",
            "--knowledge-root",
            str(connection.projection_root),
        ],
        [
            str(SCRIPT_DIR / "knowledge-index-helper.sh"),
            "build",
            str(connection.projection_root),
        ],
    )
    for command in commands:
        result = _run_bounded(
            command, connection.projection_root.parent, os.environ.copy(), timeout
        )
        if result.returncode != 0:
            return "failed"
    return "complete"


@dataclass(frozen=True)
class ExecutionHooks:
    """Injectable side effects for deterministic execution and testing."""

    dry_run: bool
    command_builder: Callable[[Connection], list[str]] = build_command
    process_runner: Callable[
        [Connection, list[str]], subprocess.CompletedProcess[str]
    ] = run_process
    projection_runner: Callable[[Connection, int], str] = _run_projection
    checkpoint: Callable[[dict[str, Any]], None] | None = None


ProjectionGroups = dict[Path, list[tuple[Connection, dict[str, Any]]]]


@dataclass
class ExecutionContext:
    """Mutable state shared across one sequential collector pass."""

    state: dict[str, Any]
    now: int
    hooks: ExecutionHooks
    groups: ProjectionGroups


def _checkpoint(state: dict[str, Any], hooks: ExecutionHooks) -> None:
    if hooks.checkpoint is not None:
        hooks.checkpoint(state)


def _queue_projection(
    groups: ProjectionGroups, connection: Connection, record: dict[str, Any]
) -> None:
    root = connection.projection_root
    if root is None:
        raise CollectorScheduleError("projection target is unavailable")
    group = groups.setdefault(root, [])
    if not any(existing_record is record for _, existing_record in group):
        group.append((connection, record))


def _run_collector(
    connection: Connection, hooks: ExecutionHooks
) -> subprocess.CompletedProcess[str]:
    command: list[str] = []
    try:
        command = hooks.command_builder(connection)
        return hooks.process_runner(connection, command)
    except (CollectorScheduleError, OSError, subprocess.SubprocessError):
        return subprocess.CompletedProcess(command, 124, "", "")


def _collect_connection(
    connection: Connection,
    record: dict[str, Any],
    context: ExecutionContext,
) -> dict[str, Any] | None:
    boundary = due_at(connection, record, context.now)
    if boundary is None or boundary > context.now:
        return None
    if context.hooks.dry_run:
        return {"connection_id": connection.connection_id, "status": "planned"}
    record.update({"last_attempt": context.now, "status": "running"})
    _checkpoint(context.state, context.hooks)
    completed = _run_collector(connection, context.hooks)
    changed = 0
    try:
        receipt = _receipt(completed.stdout, context.now)
    except CollectorScheduleError:
        receipt = None
    if receipt is None:
        _record_failure(record, connection, context.now)
    else:
        changed, projection_pending = _apply_receipt(
            record, connection, receipt, context.now, completed.returncode
        )
        if projection_pending:
            _queue_projection(context.groups, connection, record)
    _checkpoint(context.state, context.hooks)
    return {
        "connection_id": connection.connection_id,
        "status": record["status"],
        "changed_count": changed,
    }


def _apply_projection(record: dict[str, Any], projection: str) -> None:
    if projection == "failed":
        record["projection_status"] = "pending"
        if record.get("collector_outcome") == "complete":
            record["status"] = "partial"
        return
    record["projection_status"] = projection
    outcome_status = {
        "complete": "complete",
        "partial": "partial",
        "deferred": "pending",
    }
    outcome = record.get("collector_outcome")
    if outcome in outcome_status:
        record["status"] = outcome_status[outcome]


def _run_projection_group(
    group: list[tuple[Connection, dict[str, Any]]], hooks: ExecutionHooks
) -> None:
    representative = group[0][0]
    try:
        projection = hooks.projection_runner(representative, representative.timeout_seconds)
    except (OSError, subprocess.SubprocessError):
        projection = "failed"
    for _, record in group:
        _apply_projection(record, projection)


def execute_due(
    connections: list[Connection],
    state: dict[str, Any],
    now: int,
    **options: Any,
) -> list[dict[str, Any]]:
    """Execute due work sequentially and retain independent terminal receipts."""
    hooks = ExecutionHooks(**options)
    results: list[dict[str, Any]] = []
    context = ExecutionContext(state, now, hooks, {})
    for connection in connections:
        record = _record(state, connection.connection_id)
        if (
            not hooks.dry_run
            and record.get("projection_status") == "pending"
            and connection.projection_root is not None
        ):
            _queue_projection(context.groups, connection, record)
        result = _collect_connection(connection, record, context)
        if result is not None:
            results.append(result)
    for group in context.groups.values():
        _run_projection_group(group, hooks)
        _checkpoint(state, hooks)
    if not hooks.dry_run:
        result_records = state["connections"]
        for result in results:
            result["status"] = result_records[result["connection_id"]]["status"]
    return results


def write_state(path: Path, state: dict[str, Any]) -> None:
    """Atomically persist owner-only content-free state and directory metadata."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(path.parent, 0o700)
    descriptor, temporary = tempfile.mkstemp(prefix=".collector-state-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(state, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _locked(path: Path):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    handle = (path.parent / ".collector-health.lock").open("a+", encoding="utf-8")
    os.chmod(handle.name, 0o600)
    fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
    return handle


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("plan", "run", "health"))
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--now-epoch", type=int, help=argparse.SUPPRESS)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.now_epoch is not None and os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        print("ERROR: explicit clock is test-only", file=sys.stderr)
        return 1
    try:
        now = args.now_epoch if args.now_epoch is not None else int(time.time())
        connections = load_config(args.config)
        if args.command in ("plan", "health") or args.dry_run:
            state = load_state(args.state)
            if args.command in ("plan", "health"):
                result: Any = plan(connections, state, now)
            else:
                result = execute_due(
                    connections,
                    state,
                    now,
                    dry_run=args.dry_run,
                    checkpoint=None,
                )
        else:
            with _locked(args.state):
                state = load_state(args.state)
                result = execute_due(
                    connections,
                    state,
                    now,
                    dry_run=False,
                    checkpoint=lambda value: write_state(args.state, value),
                )
        print(json.dumps(result, sort_keys=True))
        return 0
    except (
        CollectorInterrupted,
        CollectorScheduleError,
        OSError,
        subprocess.SubprocessError,
    ) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
