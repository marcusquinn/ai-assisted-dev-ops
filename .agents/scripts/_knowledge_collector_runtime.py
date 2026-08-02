#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded process execution and receipt parsing for knowledge collectors."""

from __future__ import annotations

import json
import os
import re
import signal
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Any

OPAQUE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$")
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


def _descendant_pids(root_pid: int) -> list[int]:
    """Snapshot descendants so session-changing children cannot escape cleanup."""
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,ppid="], check=True, capture_output=True, text=True, timeout=2
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
        stable_scans = 0 if new_pids else stable_scans + 1
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
        return (
            cleanup_error.output or getattr(original_error, "output", None) or "",
            cleanup_error.stderr or getattr(original_error, "stderr", None) or "",
        )


def _restore_signals(
    previous_mask: set[signal.Signals], previous_handlers: dict[signal.Signals, Any]
) -> None:
    signal.pthread_sigmask(signal.SIG_SETMASK, previous_mask)
    for interrupt_signal, previous_handler in previous_handlers.items():
        signal.signal(interrupt_signal, previous_handler)


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
        _restore_signals(previous_mask, previous_handlers)
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
        _restore_signals(previous_mask, previous_handlers)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)


def _last_object(stdout: str) -> dict[str, Any]:
    for line in reversed(stdout.splitlines()):
        try:
            candidate = json.loads(line)
        except (json.JSONDecodeError, UnicodeError):
            continue
        if isinstance(candidate, dict):
            return candidate
    raise CollectorScheduleError("collector did not emit a valid receipt")


def _changed_count(value: dict[str, Any]) -> int:
    for key in CHANGE_KEYS:
        count = value.get(key)
        if isinstance(count, int) and not isinstance(count, bool) and count >= 0:
            return count
    counts = value.get("counts")
    imported = counts.get("imported") if isinstance(counts, dict) else None
    if isinstance(imported, int) and not isinstance(imported, bool) and imported >= 0:
        return imported
    raise CollectorScheduleError("collector receipt has no changed count")


def _metadata(value: dict[str, Any]) -> dict[str, Any]:
    receipt: dict[str, Any] = {"changed_count": _changed_count(value)}
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
    return receipt


def _validated_status(value: dict[str, Any]) -> tuple[str, str | None]:
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
    return status, failure_class


def _disposition(
    receipt: dict[str, Any], status: str, failure_class: str | None
) -> str:
    if status in DEFERRED_STATUSES:
        return "deferred"
    if status in PARTIAL_STATUSES or failure_class == "delta_not_supported":
        receipt.setdefault(
            "coverage_status", "unavailable" if status == "delta_unavailable" else "partial"
        )
        if status in ("budget-stopped", "budget_exhausted"):
            receipt["budget_stop"] = True
        return "partial"
    if status in FAILED_STATUSES or failure_class is not None:
        return "failed"
    if receipt.get("coverage_status") == "partial":
        return "partial"
    if status in COMPLETE_STATUSES:
        return "complete"
    raise CollectorScheduleError("collector receipt status is unsupported")


def _duration(value: Any, now: int | None) -> int:
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not 0 <= value <= 31_536_000
        or now is None
    ):
        raise CollectorScheduleError("collector retry duration is invalid")
    return now + value


def _retry_boundary(value: Any, now: int | None) -> int:
    if isinstance(value, int) and not isinstance(value, bool):
        return max(0, value)
    if not isinstance(value, str):
        raise CollectorScheduleError("collector retry boundary is invalid")
    try:
        if value.isdigit():
            if now is None:
                raise ValueError
            return now + int(value)
        parsed_retry = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed_retry.tzinfo is None:
            raise ValueError
        return int(parsed_retry.timestamp())
    except (OverflowError, ValueError) as error:
        raise CollectorScheduleError("collector retry boundary is invalid") from error


def _apply_retry(value: dict[str, Any], receipt: dict[str, Any], now: int | None) -> None:
    retry_seconds = value.get("retry_after_seconds")
    retry_after = value.get("retry_after")
    if retry_seconds is not None and retry_after is not None:
        raise CollectorScheduleError("collector receipt has ambiguous retry boundaries")
    if retry_seconds is not None:
        receipt["rate_reset_at"] = _duration(retry_seconds, now)
    elif retry_after is not None:
        receipt["rate_reset_at"] = _retry_boundary(retry_after, now)


def _receipt(stdout: str, now: int | None = None) -> dict[str, Any]:
    """Normalize the last committed content-free collector receipt."""
    value = _last_object(stdout)
    receipt = _metadata(value)
    status, failure_class = _validated_status(value)
    receipt["disposition"] = _disposition(receipt, status, failure_class)
    _apply_retry(value, receipt, now)
    return receipt
