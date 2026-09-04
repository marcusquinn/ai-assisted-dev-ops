#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded read-only Git process handling for worktree recovery."""

import os
from pathlib import Path
import selectors
import signal
import subprocess
import time
from typing import List, Optional, Tuple

GIT_OUTPUT_MAX_BYTES = 1024 * 1024
GIT_OUTPUT_LIMIT_RC = 125


def _stop_process(process: subprocess.Popen) -> None:
    """Stop a Git process group after a resource limit is reached."""
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except (OSError, ProcessLookupError):
        pass
    try:
        process.wait(timeout=0.2)
        stopped = True
    except subprocess.TimeoutExpired:
        stopped = False
    if not stopped:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (OSError, ProcessLookupError):
            pass
        try:
            process.wait(timeout=0.2)
        except subprocess.TimeoutExpired:
            pass


def _start_git_process(
    git_bin: str, source_root: Path, arguments: List[str]
) -> Optional[subprocess.Popen]:
    """Start one structured, non-shell Git query."""
    git_environment = os.environ.copy()
    git_environment["GIT_OPTIONAL_LOCKS"] = "0"
    try:
        # The trusted caller resolves git_bin; structured argv disables shell parsing.
        process = subprocess.Popen(
            [git_bin, "-C", str(source_root), *arguments],
            env=git_environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )  # nosec B603
    except OSError:
        return None
    return process


def _stream_wait_seconds(deadline_epoch: Optional[int]) -> Optional[float]:
    """Return a short stream wait or None once the shared deadline expires."""
    if deadline_epoch is None:
        return 0.1
    remaining = deadline_epoch - time.time()
    return min(0.1, remaining) if remaining > 0 else None


def _bounded_stream_output(
    process: subprocess.Popen,
    selector: selectors.BaseSelector,
    deadline_epoch: Optional[int],
) -> Tuple[Optional[int], bytearray]:
    """Read bounded stdout, returning a terminal limit code or EOF marker."""
    output = bytearray()
    while True:
        wait_seconds = _stream_wait_seconds(deadline_epoch)
        if wait_seconds is None:
            return 124, bytearray()
        events = selector.select(wait_seconds)
        if not events:
            continue
        chunk = os.read(process.stdout.fileno(), 65536)
        if not chunk:
            return None, output
        output.extend(chunk)
        if len(output) > GIT_OUTPUT_MAX_BYTES:
            return GIT_OUTPUT_LIMIT_RC, bytearray()


def _wait_for_process(
    process: subprocess.Popen, deadline_epoch: Optional[int]
) -> int:
    """Wait for process completion without extending the shared deadline."""
    wait_timeout = None
    if deadline_epoch is not None:
        wait_timeout = max(0.0, deadline_epoch - time.time())
    try:
        return process.wait(timeout=wait_timeout)
    except subprocess.TimeoutExpired:
        return 124


def _read_process_output(
    process: subprocess.Popen, deadline_epoch: Optional[int]
) -> Tuple[int, bytes]:
    """Capture bounded process output until EOF or the shared deadline."""
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        terminal_rc, output = _bounded_stream_output(process, selector, deadline_epoch)
        if terminal_rc is None:
            terminal_rc = _wait_for_process(process, deadline_epoch)
        if terminal_rc in {124, GIT_OUTPUT_LIMIT_RC}:
            _stop_process(process)
            output.clear()
    finally:
        selector.close()
        process.stdout.close()
    return terminal_rc, bytes(output)


def git_output(
    git_bin: str,
    source_root: Path,
    arguments: List[str],
    deadline_epoch: Optional[int] = None,
) -> Tuple[int, bytes]:
    """Run one read-only Git query with bounded captured output."""
    if deadline_epoch is not None and deadline_epoch <= time.time():
        return 124, b""
    process = _start_git_process(git_bin, source_root, arguments)
    if process is None or process.stdout is None:
        if process is not None:
            _stop_process(process)
        return 2, b""
    return _read_process_output(process, deadline_epoch)
