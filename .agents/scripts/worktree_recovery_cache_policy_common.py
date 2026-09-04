#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared path, process, and allocation primitives for recovery cache policy."""

import os
from pathlib import Path, PurePosixPath
import re
import selectors
import signal
import stat
import subprocess
import time
from typing import List, NamedTuple, Optional, Set, Tuple

GIT_OUTPUT_MAX_BYTES = 1024 * 1024
GIT_OUTPUT_LIMIT_RC = 125


class RootExpectation(NamedTuple):
    """Immutable cache-root identity and allocation evidence."""

    identity: str
    allocated_bytes: int


SAFE_COMPONENTS = {
    "node_modules",
    ".pnpm-store",
    ".turbo",
    ".parcel-cache",
    ".vite",
    "__pycache__",
    ".pytest_cache",
}
SAFE_CHAINS = {(".yarn", "cache"), (".next", "cache"), (".nuxt", "cache")}
SAFE_REPOSITORY_ROOTS = {".codegraph"}
SAFE_NESTED_ROOTS = SAFE_COMPONENTS | {"/".join(chain) for chain in SAFE_CHAINS}
SAFE_ROOT_PATTERN = re.compile(
    r"^(?P<root>(?:\.codegraph|(?:[^/]+/)*?(?:"
    + "|".join(re.escape(root) for root in sorted(SAFE_NESTED_ROOTS))
    + r")))(?:/|$)"
)


def safe_root(raw_path: str) -> Optional[Tuple[str, ...]]:
    """Return the narrow recognised cache root containing a status path."""
    parts = PurePosixPath(raw_path.rstrip("/")).parts
    if not parts or parts[0] in {"/", ".", ".."} or ".." in parts:
        return None
    match = SAFE_ROOT_PATTERN.match("/".join(parts))
    return tuple(match.group("root").split("/")) if match is not None else None


def ordinary_directory(root: Path, relative_parts: Tuple[str, ...]) -> Optional[Path]:
    """Resolve a directory without traversing any symlink component."""
    candidate = root
    for part in relative_parts:
        candidate = candidate / part
        if candidate.is_symlink():
            return None
    return candidate if candidate.is_dir() else None


def status_records(raw: bytes):
    """Yield porcelain state and path records without losing unusual filenames."""
    for record in filter(None, raw.split(b"\0")):
        if len(record) < 4:
            yield b"??", ""
            continue
        yield record[:2], os.fsdecode(record[3:])


def stop_process(process: subprocess.Popen) -> None:
    """Stop a Git process group after a resource limit is reached."""
    for stop_signal in (signal.SIGTERM, signal.SIGKILL):
        try:
            os.killpg(process.pid, stop_signal)
        except (OSError, ProcessLookupError):
            pass
        try:
            process.wait(timeout=0.2)
            return
        except subprocess.TimeoutExpired:
            pass


def start_git_process(
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


def stream_wait_seconds(deadline_epoch: Optional[int]) -> Optional[float]:
    """Return a short stream wait or None once the shared deadline expires."""
    if deadline_epoch is None:
        return 0.1
    remaining = deadline_epoch - time.time()
    return min(0.1, remaining) if remaining > 0 else None


def bounded_stream_output(
    process: subprocess.Popen,
    selector: selectors.BaseSelector,
    deadline_epoch: Optional[int],
) -> Tuple[Optional[int], bytearray]:
    """Read bounded stdout, returning a terminal limit code or EOF marker."""
    output = bytearray()
    while True:
        wait_seconds = stream_wait_seconds(deadline_epoch)
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


def wait_for_process(
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


def read_process_output(
    process: subprocess.Popen, deadline_epoch: Optional[int]
) -> Tuple[int, bytes]:
    """Capture bounded process output until EOF or the shared deadline."""
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        terminal_rc, output = bounded_stream_output(process, selector, deadline_epoch)
        if terminal_rc is None:
            terminal_rc = wait_for_process(process, deadline_epoch)
        if terminal_rc in {124, GIT_OUTPUT_LIMIT_RC}:
            stop_process(process)
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
    process = start_git_process(git_bin, source_root, arguments)
    if process is None or process.stdout is None:
        if process is not None:
            stop_process(process)
        return 2, b""
    return read_process_output(process, deadline_epoch)


def require(condition: bool, message: str) -> None:
    """Raise a fail-closed validation error when a safety proof is absent."""
    if not condition:
        raise ValueError(message)


def allocated_entry(
    root: Path, current: Path, deadline_epoch: int
) -> Optional[Tuple[int, List[Path]]]:
    """Measure one safe filesystem entry and return its children."""
    try:
        require(time.time() < deadline_epoch, "allocation deadline expired")
        metadata = current.lstat()
        root_is_valid = current != root or all(
            (stat.S_ISDIR(metadata.st_mode), not current.is_symlink())
        )
        require(root_is_valid, "cache root is not an ordinary directory")
        entry_is_safe = not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink == 1
        require(entry_is_safe, "cache entry is hard linked")
        children: List[Path] = []
        if stat.S_ISDIR(metadata.st_mode):
            with os.scandir(current) as entries:
                children = [Path(entry.path) for entry in entries]
    except (OSError, ValueError):
        return None
    return metadata.st_blocks * 512, children


def allocated_bytes(root: Path, deadline_epoch: int) -> Optional[int]:
    """Measure allocated bytes without following symlink entries or hard links."""
    total = 0
    stack = [root]
    while stack:
        current = stack.pop()
        measurement = allocated_entry(root, current, deadline_epoch)
        if measurement is None:
            return None
        allocated, children = measurement
        total += allocated
        stack.extend(children)
    return total


def exact_safe_root(relative_path: str) -> Optional[Tuple[str, ...]]:
    """Return a safe root only when the supplied path is exactly that root."""
    parts = PurePosixPath(relative_path).parts
    return {parts: parts}.get(safe_root(relative_path))


def root_identity(path: Path) -> Optional[str]:
    """Return a non-following device/inode identity for an ordinary directory."""
    try:
        metadata = path.lstat()
    except OSError:
        return None
    identity = f"{metadata.st_dev}:{metadata.st_ino}"
    is_ordinary_directory = all((stat.S_ISDIR(metadata.st_mode), not path.is_symlink()))
    return {True: identity}.get(is_ordinary_directory)


def ignored_untracked_root(
    archive_root: Path,
    relative_root: str,
    git_bin: str,
    deadline_epoch: int,
) -> bool:
    """Prove that an exact approved root is ignored and contains no tracked path."""
    ignored_rc, _ = git_output(
        git_bin, archive_root, ["check-ignore", "-q", "--", relative_root], deadline_epoch
    )
    if ignored_rc != 0:
        return False
    tracked_rc, tracked = git_output(
        git_bin, archive_root, ["ls-files", "-z", "--", relative_root], deadline_epoch
    )
    return tracked_rc == 0 and not tracked
