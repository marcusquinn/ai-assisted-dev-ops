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
import signal
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any, Callable

SCHEMA = "aidevops.knowledge-collector/v1"
MODES = frozenset(("event", "poll", "watch", "archive", "manual", "hybrid"))
OPAQUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
SCRIPT_DIR = Path(__file__).resolve().parent
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
CHANGE_KEYS = (
    "changed_count",
    "fetched_count",
    "normalized_items",
    "resource_count",
    "resources",
    "processed",
)
COUNT_KEYS = ("pages", "items", "bytes", "budget_units")
COVERAGE_STATES = frozenset(("complete", "partial", "unavailable", "unknown"))
OPTIONAL_RECEIPT_KEYS = (*COUNT_KEYS, "rate_reset_at", "coverage_status", "budget_stop")
DEFERRED_STATUSES = frozenset(("busy", "deferred", "rate_limited"))
PARTIAL_STATUSES = frozenset(
    ("budget-stopped", "budget_exhausted", "delta_unavailable", "partial", "partial_error")
)
FAILED_STATUSES = frozenset(("error", "failed"))
COMPLETE_STATUSES = frozenset(("complete", "ok", "success"))


class CollectorScheduleError(ValueError):
    """Raised for a privacy-safe collector scheduling failure."""


class CollectorInterrupted(Exception):
    """Raised after an external interrupt safely terminates the active collector."""


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


def _connection(value: Any) -> Connection:
    if not isinstance(value, dict):
        raise CollectorScheduleError("collector connection must be an object")
    connection_id = value.get("connection_id")
    connector_id = value.get("connector_id")
    mode = value.get("mode")
    if not isinstance(connection_id, str) or not OPAQUE.fullmatch(connection_id):
        raise CollectorScheduleError("connection_id must be opaque")
    if connector_id not in CONNECTORS:
        raise CollectorScheduleError("connector_id is not allowlisted")
    if mode not in MODES:
        raise CollectorScheduleError("collector mode is invalid")
    arguments = value.get("arguments", [])
    if (
        not isinstance(arguments, list)
        or len(arguments) > 64
        or any(not isinstance(item, str) or len(item) > 1024 or "\x00" in item for item in arguments)
    ):
        raise CollectorScheduleError("collector arguments are invalid")
    working = value.get("working_directory", ".")
    if not isinstance(working, str):
        raise CollectorScheduleError("working_directory must be text")
    working_directory = Path(working).expanduser().resolve()
    if not working_directory.is_dir():
        raise CollectorScheduleError("working_directory is unavailable")
    projection_value = value.get("projection_root")
    projection_root: Path | None = None
    if connector_id == "social":
        if projection_value is not None:
            raise CollectorScheduleError("social collectors update their own query index")
    elif mode not in ("archive", "manual"):
        if not isinstance(projection_value, str):
            raise CollectorScheduleError("active document collectors require projection_root")
        projection_root = Path(projection_value).expanduser().resolve()
        if not projection_root.is_dir():
            raise CollectorScheduleError("projection_root is unavailable")
    elif projection_value is not None:
        if not isinstance(projection_value, str):
            raise CollectorScheduleError("projection_root must be text")
        projection_root = Path(projection_value).expanduser().resolve()
        if not projection_root.is_dir():
            raise CollectorScheduleError("projection_root is unavailable")
    if value.get("enabled", False) is True and "--dry-run" in arguments:
        raise CollectorScheduleError("enabled collectors cannot use --dry-run")
    event_token = value.get("event_token")
    if event_token is not None and (
        not isinstance(event_token, str) or not OPAQUE.fullmatch(event_token)
    ):
        raise CollectorScheduleError("event_token must be opaque")
    if value.get("event_pending", False) is True and event_token is None:
        raise CollectorScheduleError("event_pending requires an event_token")
    return Connection(
        connection_id,
        connector_id,
        mode,
        tuple(arguments),
        working_directory,
        projection_root,
        _integer(value.get("freshness_seconds", 3600), "freshness_seconds", 60, 31_536_000),
        _integer(value.get("minimum_interval_seconds", 60), "minimum_interval_seconds", 60, 31_536_000),
        _integer(value.get("reconcile_seconds", 86_400), "reconcile_seconds", 60, 31_536_000),
        _integer(value.get("stale_seconds", 7200), "stale_seconds", 60, 31_536_000),
        _integer(value.get("budget", {}).get("seconds", 300), "budget.seconds", 1, 3600)
        if isinstance(value.get("budget", {}), dict)
        else _integer(None, "budget", 1, 3600),
        _integer(value.get("alert_after_failures", 3), "alert_after_failures", 1, 100),
        event_token,
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
    if not connection.enabled:
        return "disabled"
    if connection.mode in ("archive", "manual"):
        return "manual"
    if record.get("status") == "running":
        return "pending"
    rate_reset = record.get("rate_reset_at")
    if isinstance(rate_reset, int) and rate_reset > now:
        return "rate-reset"
    failures = record.get("consecutive_failures", 0)
    if isinstance(failures, int) and failures >= connection.alert_after_failures:
        return "terminal-failure"
    if record.get("status") == "pending":
        return "pending"
    if record.get("status") == "partial" or record.get("coverage_status") == "partial":
        return "partial"
    last_success = record.get("last_success", 0)
    freshness_reference = last_success or record.get("last_attempt", 0)
    if freshness_reference and now - freshness_reference > connection.stale_seconds:
        return "stale"
    return "healthy" if last_success else "pending"


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


def _descendant_pids(root_pid: int) -> list[int]:
    """Snapshot descendants so session-changing children cannot escape cleanup."""
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid="],
            check=True,
            capture_output=True,
            text=True,
            timeout=2,
        )
    except (OSError, subprocess.SubprocessError):
        return []
    children: dict[int, list[int]] = {}
    for line in result.stdout.splitlines():
        fields = line.split()
        if len(fields) != 2 or not all(field.isdigit() for field in fields):
            continue
        pid, parent = (int(field) for field in fields)
        children.setdefault(parent, []).append(pid)
    descendants: list[int] = []
    pending = [root_pid]
    while pending:
        current = pending.pop()
        direct = children.get(current, [])
        descendants.extend(direct)
        pending.extend(direct)
    return list(reversed(descendants))


def _signal_pids(pids: list[int], requested_signal: signal.Signals) -> None:
    for pid in pids:
        try:
            os.kill(pid, requested_signal)
        except ProcessLookupError:
            continue


def _signal_group(pid: int, requested_signal: signal.Signals) -> None:
    try:
        os.killpg(pid, requested_signal)
    except ProcessLookupError:
        return


def _freeze_process_tree(root_pid: int) -> list[int]:
    """Freeze a process tree to a fixed point before terminal cleanup."""
    _signal_group(root_pid, signal.SIGSTOP)
    descendants: set[int] = set()
    stable_scans = 0
    for _ in range(8):
        current = set(_descendant_pids(root_pid))
        new_pids = current - descendants
        _signal_pids(sorted(new_pids), signal.SIGSTOP)
        descendants.update(current)
        if new_pids:
            stable_scans = 0
        else:
            stable_scans += 1
            if stable_scans == 2:
                break
        time.sleep(0.01)
    return sorted(descendants, reverse=True)


def _close_process_pipes(process: subprocess.Popen[str]) -> None:
    for stream in (process.stdout, process.stderr):
        if stream is not None:
            stream.close()


def _terminate_process_tree(
    process: subprocess.Popen[str], original_error: BaseException
) -> tuple[str | bytes, str | bytes]:
    descendants = _freeze_process_tree(process.pid)
    _signal_pids(descendants, signal.SIGKILL)
    _signal_group(process.pid, signal.SIGKILL)
    try:
        return process.communicate(timeout=2)
    except subprocess.TimeoutExpired as cleanup_error:
        _close_process_pipes(process)
        if process.poll() is None:
            process.kill()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
        original_output = getattr(original_error, "output", None)
        original_stderr = getattr(original_error, "stderr", None)
        return (
            cleanup_error.output or original_output or "",
            cleanup_error.stderr or original_stderr or "",
        )


def _run_bounded(
    command: list[str], working_directory: Path, environment: dict[str, str], timeout: int
) -> subprocess.CompletedProcess[str]:
    """Execute one process group and terminate every descendant at its deadline."""
    interrupt_signals = (signal.SIGINT, signal.SIGTERM)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, interrupt_signals)
    previous_handlers: dict[signal.Signals, Any] = {}

    def interrupt(signum: int, _frame: Any) -> None:
        raise CollectorInterrupted(signum)

    for interrupt_signal in interrupt_signals:
        previous_handlers[interrupt_signal] = signal.signal(interrupt_signal, interrupt)
    try:
        process = subprocess.Popen(
            command,
            cwd=working_directory,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
    except BaseException:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        for interrupt_signal, previous_handler in previous_handlers.items():
            signal.signal(interrupt_signal, previous_handler)
        raise
    try:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        for interrupt_signal in interrupt_signals:
            signal.signal(interrupt_signal, signal.SIG_IGN)
        stdout, stderr = _terminate_process_tree(process, error)
        raise subprocess.TimeoutExpired(
            command, timeout, output=stdout, stderr=stderr
        ) from error
    except CollectorInterrupted as error:
        for interrupt_signal in interrupt_signals:
            signal.signal(interrupt_signal, signal.SIG_IGN)
        _terminate_process_tree(process, error)
        raise
    finally:
        signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
        for interrupt_signal, previous_handler in previous_handlers.items():
            signal.signal(interrupt_signal, previous_handler)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def run_process(connection: Connection, command: list[str]) -> subprocess.CompletedProcess[str]:
    """Execute one bounded collector without a shell or inherited content output."""
    environment = os.environ.copy()
    environment["AIDEVOPS_COLLECTOR_RECEIPT"] = "1"
    return _run_bounded(
        command, connection.working_directory, environment, connection.timeout_seconds
    )


def _receipt(stdout: str, now: int | None = None) -> dict[str, Any]:
    value: Any = None
    for line in reversed(stdout.splitlines()):
        try:
            candidate = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            continue
        if isinstance(candidate, dict):
            value = candidate
            break
    if not isinstance(value, dict):
        raise CollectorScheduleError("collector did not emit a valid receipt")
    receipt: dict[str, Any] = {}
    for key in CHANGE_KEYS:
        count = value.get(key)
        if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
            receipt["changed_count"] = count
            break
    counts = value.get("counts")
    if "changed_count" not in receipt and isinstance(counts, dict):
        imported = counts.get("imported")
        if isinstance(imported, int) and not isinstance(imported, bool) and imported >= 0:
            receipt["changed_count"] = imported
    if "changed_count" not in receipt:
        raise CollectorScheduleError("collector receipt has no changed count")
    for key in COUNT_KEYS:
        count = value.get(key)
        if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
            receipt[key] = count
    rate_reset = value.get("rate_reset_at")
    if isinstance(rate_reset, int) and not isinstance(rate_reset, bool) and rate_reset >= 0:
        receipt["rate_reset_at"] = rate_reset
    coverage = value.get("coverage_status")
    if coverage in COVERAGE_STATES:
        receipt["coverage_status"] = coverage
    if isinstance(value.get("budget_stop"), bool):
        receipt["budget_stop"] = value["budget_stop"]
    if value.get("commit_state") in ("dry-run", "planned"):
        raise CollectorScheduleError("collector receipt reports an uncommitted run")
    status = value.get("collector_status", value.get("status", "complete"))
    failure_class = value.get("failure_class")
    if not isinstance(status, str) or not OPAQUE.fullmatch(status):
        raise CollectorScheduleError("collector receipt status is invalid")
    if failure_class is not None and (
        not isinstance(failure_class, str) or not OPAQUE.fullmatch(failure_class)
    ):
        raise CollectorScheduleError("collector receipt failure class is invalid")
    if status in DEFERRED_STATUSES:
        receipt["disposition"] = "deferred"
    elif status in PARTIAL_STATUSES or failure_class == "delta_not_supported":
        receipt["disposition"] = "partial"
        receipt.setdefault(
            "coverage_status", "unavailable" if status == "delta_unavailable" else "partial"
        )
        if status in ("budget-stopped", "budget_exhausted"):
            receipt["budget_stop"] = True
    elif status in FAILED_STATUSES or failure_class is not None:
        receipt["disposition"] = "failed"
    elif receipt.get("coverage_status") == "partial":
        receipt["disposition"] = "partial"
    elif status in COMPLETE_STATUSES:
        receipt["disposition"] = "complete"
    else:
        raise CollectorScheduleError("collector receipt status is unsupported")
    retry_seconds = value.get("retry_after_seconds")
    retry_after = value.get("retry_after")
    if retry_seconds is not None and retry_after is not None:
        raise CollectorScheduleError("collector receipt has ambiguous retry boundaries")
    if retry_seconds is not None:
        if isinstance(retry_seconds, str) and retry_seconds.isdigit():
            retry_seconds = int(retry_seconds)
        if (
            isinstance(retry_seconds, bool)
            or not isinstance(retry_seconds, int)
            or not 0 <= retry_seconds <= 31_536_000
            or now is None
        ):
            raise CollectorScheduleError("collector retry duration is invalid")
        receipt["rate_reset_at"] = now + retry_seconds
    elif isinstance(retry_after, int) and not isinstance(retry_after, bool):
        receipt["rate_reset_at"] = max(0, retry_after)
    elif isinstance(retry_after, str):
        try:
            if retry_after.isdigit():
                if now is None:
                    raise ValueError
                receipt["rate_reset_at"] = now + int(retry_after)
            else:
                parsed_retry = datetime.fromisoformat(retry_after.replace("Z", "+00:00"))
                if parsed_retry.tzinfo is None:
                    raise ValueError
                receipt["rate_reset_at"] = int(parsed_retry.timestamp())
        except (OverflowError, ValueError) as error:
            raise CollectorScheduleError("collector retry boundary is invalid") from error
    return receipt


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


def execute_due(
    connections: list[Connection],
    state: dict[str, Any],
    now: int,
    *,
    dry_run: bool,
    command_builder: Callable[[Connection], list[str]] = build_command,
    process_runner: Callable[[Connection, list[str]], subprocess.CompletedProcess[str]] = run_process,
    projection_runner: Callable[[Connection, int], str] = _run_projection,
    checkpoint: Callable[[dict[str, Any]], None] | None = None,
) -> list[dict[str, Any]]:
    """Execute due work sequentially and retain independent terminal receipts."""
    results = []
    changed_by_directory: dict[Path, list[tuple[Connection, dict[str, Any]]]] = {}
    for connection in connections:
        record = _record(state, connection.connection_id)
        if not dry_run and (
            record.get("projection_status") == "pending"
            and connection.projection_root is not None
        ):
            changed_by_directory.setdefault(connection.projection_root, []).append(
                (connection, record)
            )
        boundary = due_at(connection, record, now)
        if boundary is None or boundary > now:
            continue
        if dry_run:
            results.append({"connection_id": connection.connection_id, "status": "planned"})
            continue
        record.update({"last_attempt": now, "status": "running"})
        if checkpoint is not None:
            checkpoint(state)
        command: list[str] = []
        try:
            command = command_builder(connection)
            completed = process_runner(connection, command)
        except (CollectorScheduleError, OSError, subprocess.SubprocessError):
            completed = subprocess.CompletedProcess(command, 124, "", "")
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
            if projection_pending and not any(
                existing_record is record
                for _, existing_record in changed_by_directory.get(
                    connection.projection_root, []
                )
            ):
                if connection.projection_root is None:
                    raise CollectorScheduleError("projection target is unavailable")
                changed_by_directory.setdefault(connection.projection_root, []).append(
                    (connection, record)
                )
        if checkpoint is not None:
            checkpoint(state)
        results.append(
            {
                "connection_id": connection.connection_id,
                "status": record["status"],
                "changed_count": changed,
            }
        )
    for group in changed_by_directory.values():
        representative = group[0][0]
        try:
            projection = projection_runner(representative, representative.timeout_seconds)
        except (OSError, subprocess.SubprocessError):
            projection = "failed"
        for _, record in group:
            if projection == "failed":
                record["projection_status"] = "pending"
                if record.get("collector_outcome") == "complete":
                    record["status"] = "partial"
            else:
                record["projection_status"] = projection
                outcome = record.get("collector_outcome")
                if outcome == "complete":
                    record["status"] = "complete"
                elif outcome == "partial":
                    record["status"] = "partial"
                elif outcome == "deferred":
                    record["status"] = "pending"
        if checkpoint is not None:
            checkpoint(state)
    if not dry_run:
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
