#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded process execution for knowledge collectors."""

from __future__ import annotations

import os
import shutil
import signal
import subprocess
import time
from pathlib import Path
from typing import Any


class CollectorInterrupted(Exception):
    """Raised after an external interrupt safely terminates the active collector."""


def _descendant_pids(root_pid: int) -> list[int]:
    ps = shutil.which("ps")
    if ps is None:
        return []
    try:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        result = subprocess.run(  # nosec B603 -- resolved system process viewer and fixed argv.
            [ps, "-axo", "pid=,ppid="], check=True, capture_output=True, text=True, timeout=2
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


def _terminate_process_tree(
    process: subprocess.Popen[str], original_error: BaseException
) -> tuple[str | bytes, str | bytes]:
    descendants = _freeze_process_tree(process.pid)
    _signal_pids(descendants, signal.SIGKILL)
    _signal_group(process.pid, signal.SIGKILL)
    try:
        return process.communicate(timeout=2)
    except subprocess.TimeoutExpired as cleanup_error:
        for stream in (process.stdout, process.stderr):
            if stream is not None:
                stream.close()
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
    if not command or not all(isinstance(argument, str) for argument in command):
        raise ValueError("collector command must be a non-empty string argv vector")
    executable = Path(command[0])
    if not executable.is_absolute():
        raise ValueError("collector command must begin with an absolute executable path")
    executable = executable.resolve(strict=True)
    if (
        not executable.is_file()
        or not os.access(executable, os.X_OK)
    ):
        raise ValueError("collector command must begin with an executable absolute path")
    command = [str(executable), *command[1:]]
    interrupt_signals = (signal.SIGINT, signal.SIGTERM)
    previous_mask = signal.pthread_sigmask(signal.SIG_BLOCK, interrupt_signals)
    previous_handlers: dict[signal.Signals, Any] = {}

    def interrupt(signum: int, _frame: Any) -> None:
        raise CollectorInterrupted(signum)

    for interrupt_signal in interrupt_signals:
        previous_handlers[interrupt_signal] = signal.signal(interrupt_signal, interrupt)
    try:
        # nosemgrep: python.lang.security.audit.dangerous-subprocess-use-audit.dangerous-subprocess-use-audit
        process = subprocess.Popen(  # nosec B603 -- validated absolute collector entrypoint and structured argv.
            command, cwd=working_directory, env=environment, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, start_new_session=True
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
        raise subprocess.TimeoutExpired(command, timeout, output=stdout, stderr=stderr) from error
    except CollectorInterrupted as error:
        for interrupt_signal in interrupt_signals:
            signal.signal(interrupt_signal, signal.SIG_IGN)
        _terminate_process_tree(process, error)
        raise
    finally:
        _restore_signals(previous_mask, previous_handlers)
    return subprocess.CompletedProcess(command, process.returncode, stdout, stderr)
