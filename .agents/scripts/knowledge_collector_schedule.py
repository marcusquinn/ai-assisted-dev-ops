#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Plan, execute, and report deterministic knowledge collector freshness."""

from __future__ import annotations

import argparse
import fcntl
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

SCHEMA = "aidevops.knowledge-collector/v1"
MODES = frozenset(("event", "poll", "watch", "archive", "manual", "hybrid"))
OPAQUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

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
CONNECTORS = {
    "folder": (SCRIPT_DIR / "knowledge-helper.sh", "folder", "import"),
    "inbox-watch": (SCRIPT_DIR / "inbox-watch-routine.sh",),
    "mailbox": (SCRIPT_DIR / "email-poll-helper.sh", "tick"),
    "social": (SCRIPT_DIR / "knowledge-social-helper.sh", "provider-run"),
}
COUNT_KEYS = ("pages", "items", "bytes", "budget_units")
OPTIONAL_RECEIPT_KEYS = (*COUNT_KEYS, "rate_reset_at", "coverage_status", "budget_stop")


@dataclass(frozen=True)
class Connection:
    """One validated private source schedule."""

    connection_id: str
    connector_id: str
    mode: str
    arguments: tuple[str, ...]
    working_directory: Path
    projection_root: Path | None
    freshness_seconds: int
    minimum_interval_seconds: int
    reconcile_seconds: int
    stale_seconds: int
    timeout_seconds: int
    alert_after_failures: int
    event_token: str | None
    enabled: bool


def _private_json(path: Path, label: str, *, optional: bool = False) -> dict[str, Any]:
    if optional and not path.exists():
        return {}
    if path.is_symlink() or not path.is_file():
        raise CollectorScheduleError(f"{label} must be a regular non-symlink file")
    if path.stat().st_mode & 0o077:
        raise CollectorScheduleError(f"{label} must use owner-only permissions")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise CollectorScheduleError(f"{label} is not valid private JSON") from error
    if not isinstance(value, dict):
        raise CollectorScheduleError(f"{label} root must be an object")
    return value


def _integer(value: Any, label: str, minimum: int, maximum: int) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or not minimum <= value <= maximum:
        raise CollectorScheduleError(f"{label} must be between {minimum} and {maximum}")
    return value


def _opaque_field(value: Any, label: str) -> str:
    if not isinstance(value, str) or not OPAQUE.fullmatch(value):
        raise CollectorScheduleError(f"{label} must be opaque")
    return value


def _arguments(value: Any) -> tuple[str, ...]:
    if (
        not isinstance(value, list)
        or len(value) > 64
        or any(not isinstance(item, str) or len(item) > 1024 or "\x00" in item for item in value)
    ):
        raise CollectorScheduleError("collector arguments are invalid")
    return tuple(value)


def _directory(value: Any, label: str) -> Path:
    if not isinstance(value, str):
        raise CollectorScheduleError(f"{label} must be text")
    directory = Path(value).expanduser().resolve()
    if not directory.is_dir():
        raise CollectorScheduleError(f"{label} is unavailable")
    return directory


def _projection_root(value: Any, connector_id: str, mode: str) -> Path | None:
    projection_value = value.get("projection_root")
    if connector_id == "social":
        if projection_value is not None:
            raise CollectorScheduleError("social collectors update their own query index")
        return None
    if mode not in ("archive", "manual") and projection_value is None:
        raise CollectorScheduleError("active document collectors require projection_root")
    if projection_value is None:
        return None
    return _directory(projection_value, "projection_root")


def _event_token(value: Any) -> str | None:
    event_token = value.get("event_token")
    if event_token is not None:
        event_token = _opaque_field(event_token, "event_token")
    if value.get("event_pending", False) is True and event_token is None:
        raise CollectorScheduleError("event_pending requires an event_token")
    return event_token


def _connection(value: Any) -> Connection:
    if not isinstance(value, dict):
        raise CollectorScheduleError("collector connection must be an object")
    connection_id = _opaque_field(value.get("connection_id"), "connection_id")
    connector_id = value.get("connector_id")
    mode = value.get("mode")
    if connector_id not in CONNECTORS:
        raise CollectorScheduleError("connector_id is not allowlisted")
    if mode not in MODES:
        raise CollectorScheduleError("collector mode is invalid")
    arguments = _arguments(value.get("arguments", []))
    if value.get("enabled", False) is True and "--dry-run" in arguments:
        raise CollectorScheduleError("enabled collectors cannot use --dry-run")
    return Connection(
        connection_id,
        connector_id,
        mode,
        arguments,
        _directory(value.get("working_directory", "."), "working_directory"),
        _projection_root(value, connector_id, mode),
        _integer(value.get("freshness_seconds", 3600), "freshness_seconds", 60, 31_536_000),
        _integer(value.get("minimum_interval_seconds", 60), "minimum_interval_seconds", 60, 31_536_000),
        _integer(value.get("reconcile_seconds", 86_400), "reconcile_seconds", 60, 31_536_000),
        _integer(value.get("stale_seconds", 7200), "stale_seconds", 60, 31_536_000),
        _integer(value.get("budget", {}).get("seconds", 300), "budget.seconds", 1, 3600)
        if isinstance(value.get("budget", {}), dict)
        else _integer(None, "budget", 1, 3600),
        _integer(value.get("alert_after_failures", 3), "alert_after_failures", 1, 100),
        _event_token(value),
        value.get("enabled", False) is True,
    )


def load_config(path: Path) -> list[Connection]:
    """Load a private versioned connection registry."""
    value = _private_json(path, "collector config")
    if value.get("schema") != SCHEMA:
        raise CollectorScheduleError("collector config schema is unsupported")
    raw = value.get("connections")
    if not isinstance(raw, list):
        raise CollectorScheduleError("collector config connections must be an array")
    connections = [_connection(item) for item in raw]
    keys = [item.connection_id for item in connections]
    if len(keys) != len(set(keys)):
        raise CollectorScheduleError("collector connection_id values must be unique")
    return sorted(connections, key=lambda item: item.connection_id)


def load_state(path: Path) -> dict[str, Any]:
    """Load content-free state or initialize an empty state."""
    value = _private_json(path, "collector state", optional=True)
    if not value:
        return {"schema": SCHEMA, "connections": {}}
    if value.get("schema") != SCHEMA or not isinstance(value.get("connections"), dict):
        raise CollectorScheduleError("collector state schema is unsupported")
    return value


def _record(state: dict[str, Any], connection_id: str) -> dict[str, Any]:
    records = state["connections"]
    value = records.setdefault(connection_id, {})
    if not isinstance(value, dict):
        raise CollectorScheduleError("collector state record is invalid")
    return value


def due_at(connection: Connection, record: dict[str, Any], now: int) -> int | None:
    """Return the deterministic due boundary or None for manual sources."""
    if not connection.enabled or connection.mode in ("archive", "manual"):
        return None
    rate_reset = record.get("rate_reset_at")
    if isinstance(rate_reset, int) and rate_reset > now:
        return rate_reset
    last_attempt = record.get("last_attempt", 0)
    last_success = record.get("last_success", 0)
    interval_floor = last_attempt + connection.minimum_interval_seconds
    if connection.mode in ("event", "hybrid"):
        pending_event = (
            connection.event_token is not None
            and connection.event_token != record.get("event_token")
        )
        event_due = now if pending_event else last_success + connection.reconcile_seconds
        return max(interval_floor, event_due)
    return max(interval_floor, last_success + connection.freshness_seconds)


def _health(connection: Connection, record: dict[str, Any], now: int) -> str:
    health = "healthy" if record.get("last_success", 0) else "pending"
    if not connection.enabled:
        health = "disabled"
    elif connection.mode in ("archive", "manual"):
        health = "manual"
    elif record.get("status") == "running":
        health = "pending"
    elif isinstance(record.get("rate_reset_at"), int) and record["rate_reset_at"] > now:
        health = "rate-reset"
    elif isinstance(record.get("consecutive_failures", 0), int) and record.get(
        "consecutive_failures", 0
    ) >= connection.alert_after_failures:
        health = "terminal-failure"
    elif record.get("status") == "pending":
        health = "pending"
    elif record.get("status") == "partial" or record.get("coverage_status") == "partial":
        health = "partial"
    else:
        freshness_reference = record.get("last_success", 0) or record.get("last_attempt", 0)
        if freshness_reference and now - freshness_reference > connection.stale_seconds:
            health = "stale"
    return health


def plan(connections: list[Connection], state: dict[str, Any], now: int) -> list[dict[str, Any]]:
    """Return a sorted privacy-safe due and health plan."""
    result = []
    for connection in connections:
        record = _record(state, connection.connection_id)
        boundary = due_at(connection, record, now)
        health = _health(connection, record, now)
        last_success = record.get("last_success", 0)
        result.append(
            {
                "connection_id": connection.connection_id,
                "connector_id": connection.connector_id,
                "due": boundary is not None and boundary <= now,
                "freshness_lag_seconds": now - last_success if last_success else None,
                "health": health,
                "missed_sla": health in ("stale", "terminal-failure"),
                "mode": connection.mode,
                "next_due": boundary,
            }
        )
    return result


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


def _record_failure(record: dict[str, Any], connection: Connection, now: int) -> None:
    failures = int(record.get("consecutive_failures", 0)) + 1
    record.update(
        {
            "alert": failures >= connection.alert_after_failures,
            "collector_outcome": "failed",
            "consecutive_failures": failures,
            "last_terminal_failure": now,
            "status": "failed",
        }
    )


def _apply_receipt(
    record: dict[str, Any],
    connection: Connection,
    receipt: dict[str, Any],
    now: int,
    returncode: int,
) -> tuple[int, bool]:
    changed = receipt.pop("changed_count")
    disposition = receipt.pop("disposition")
    if returncode != 0 and disposition == "complete":
        disposition = "failed"
    projection_pending = connection.projection_root is not None and (
        changed > 0 or record.get("projection_status") == "pending"
    )
    for key in OPTIONAL_RECEIPT_KEYS:
        record.pop(key, None)
    record.update(
        {
            "changed_count": changed,
            "collector_outcome": disposition,
            "projection_status": "pending" if projection_pending else "not-needed",
            **receipt,
        }
    )
    if disposition == "failed":
        _record_failure(record, connection, now)
    elif disposition == "deferred":
        record.update({"last_deferred": now, "status": "pending"})
    elif disposition == "partial":
        record.update({"last_partial": now, "status": "partial"})
    else:
        record.update(
            {
                "alert": False,
                "consecutive_failures": 0,
                "last_success": now,
                "status": "partial" if projection_pending else "complete",
            }
        )
        if connection.event_token is not None:
            record["event_token"] = connection.event_token
    return changed, projection_pending


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
    state: dict[str, Any],
    now: int,
    hooks: ExecutionHooks,
    groups: ProjectionGroups,
) -> dict[str, Any] | None:
    boundary = due_at(connection, record, now)
    if boundary is None or boundary > now:
        return None
    if hooks.dry_run:
        return {"connection_id": connection.connection_id, "status": "planned"}
    record.update({"last_attempt": now, "status": "running"})
    _checkpoint(state, hooks)
    completed = _run_collector(connection, hooks)
    changed = 0
    try:
        receipt = _receipt(completed.stdout, now)
    except CollectorScheduleError:
        receipt = None
    if receipt is None:
        _record_failure(record, connection, now)
    else:
        changed, projection_pending = _apply_receipt(
            record, connection, receipt, now, completed.returncode
        )
        if projection_pending:
            _queue_projection(groups, connection, record)
    _checkpoint(state, hooks)
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
    *,
    dry_run: bool,
    **overrides: Any,
) -> list[dict[str, Any]]:
    """Execute due work sequentially and retain independent terminal receipts."""
    hooks = ExecutionHooks(dry_run=dry_run, **overrides)
    results: list[dict[str, Any]] = []
    groups: ProjectionGroups = {}
    for connection in connections:
        record = _record(state, connection.connection_id)
        if (
            not hooks.dry_run
            and record.get("projection_status") == "pending"
            and connection.projection_root is not None
        ):
            _queue_projection(groups, connection, record)
        result = _collect_connection(connection, record, state, now, hooks, groups)
        if result is not None:
            results.append(result)
    for group in groups.values():
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
