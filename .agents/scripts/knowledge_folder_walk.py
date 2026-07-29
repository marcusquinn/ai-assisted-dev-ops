#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Descriptor-relative traversal, limits, and scan leases for folder ingestion."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
import stat
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from knowledge_folder_types import excluded, sanitize_reason


DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
FILE_FLAGS = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)


class FolderWalkError(ValueError):
    """Traversal or lease state cannot preserve scan confinement."""


@dataclass(frozen=True)
class InventoryItem:
    """One descriptor-relative traversal observation."""

    relative: str
    name: str
    descriptor: int | None
    info: os.stat_result
    disposition: str | None = None


@dataclass
class RootHandle:
    """One opened root used for both identity and traversal."""

    descriptor: int
    root_id: str

    def __enter__(self) -> "RootHandle":
        return self

    def __exit__(self, _kind: object, _value: object, _traceback: object) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


class Lease:
    """OS-locked root lease; the stable file is never unlinked by a writer."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.descriptor = -1

    def __enter__(self) -> "Lease":
        if self.path.parent.is_symlink() or not self.path.parent.is_dir() or self.path.is_symlink():
            raise FolderWalkError("folder lease path is unsafe")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        self.descriptor = os.open(self.path, flags, 0o600)
        try:
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            os.close(self.descriptor)
            self.descriptor = -1
            raise FolderWalkError("another scan holds the folder lease") from error
        os.ftruncate(self.descriptor, 0)
        os.write(self.descriptor, json.dumps({"locked_at": _utc_now()}).encode("utf-8") + b"\n")
        os.fsync(self.descriptor)
        return self

    def assert_owned(self) -> None:
        """Reject a replaced lease inode before publishing another checkpoint."""
        if self.descriptor < 0:
            raise FolderWalkError("folder lease is not held")
        held = os.fstat(self.descriptor)
        try:
            visible = self.path.stat(follow_symlinks=False)
        except OSError as error:
            raise FolderWalkError("folder lease was replaced") from error
        if (held.st_dev, held.st_ino) != (visible.st_dev, visible.st_ino):
            raise FolderWalkError("folder lease was replaced")

    def __exit__(self, _kind: object, _value: object, _traceback: object) -> None:
        if self.descriptor >= 0:
            fcntl.flock(self.descriptor, fcntl.LOCK_UN)
            os.close(self.descriptor)
            self.descriptor = -1


def open_root(root: Path, allow_roots: list[Path]) -> RootHandle:
    """Open one permitted root and derive identity from that same descriptor."""
    if root.is_symlink() or not root.is_dir():
        raise FolderWalkError("folder root must be a regular non-symlink directory")
    descriptor = os.open(root, DIRECTORY_FLAGS)
    try:
        opened = os.fstat(descriptor)
        resolved = root.resolve(strict=True)
        expected = root.stat(follow_symlinks=False)
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            raise FolderWalkError("folder root changed during scan startup")
        permitted = allow_roots or [resolved]
        for allowed in permitted:
            if allowed.is_symlink() or not allowed.is_dir():
                continue
            allowed_resolved = allowed.resolve(strict=True)
            try:
                resolved.relative_to(allowed_resolved)
            except ValueError:
                continue
            identity = f"{opened.st_dev}:{opened.st_ino}".encode("ascii")
            root_id = f"root-{hashlib.sha256(identity).hexdigest()[:24]}"
            handle = RootHandle(descriptor, root_id)
            descriptor = -1
            return handle
        raise FolderWalkError("folder root is outside the allowed roots")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def validate_limits(args: argparse.Namespace) -> None:
    """Reject negative or unbounded-by-mistake command values."""
    values = (args.max_files, args.max_nodes, args.max_bytes, args.max_item_bytes, args.max_seconds)
    if args.max_depth < 0 or any(value <= 0 for value in values):
        raise FolderWalkError("folder limits must be positive and max-depth cannot be negative")


def secure_child_directory(base: Path, *components: str, create: bool = True) -> Path:
    """Create private state components while rejecting symlinked ancestors."""
    if base.is_symlink() or not base.is_dir():
        raise FolderWalkError("knowledge state root is unsafe")
    current = base
    missing = False
    for component in components:
        current = current / component
        if missing:
            continue
        if not current.exists():
            if not create:
                missing = True
                continue
            current.mkdir(mode=0o700)
        if current.is_symlink() or not current.is_dir():
            raise FolderWalkError("knowledge state directory is unsafe")
    return current


def walk(
    root: RootHandle,
    exclude_patterns: list[str],
    max_depth: int,
    deadline: float,
    max_nodes: int,
) -> Iterator[InventoryItem]:
    """Walk beneath an opened root without following path replacements or symlinks."""
    root_descriptor = os.dup(root.descriptor)
    expected = os.fstat(root_descriptor)
    visited_nodes = 0
    budget_stopped = False

    def visit(directory_descriptor: int, prefix: str, depth: int) -> Iterator[InventoryItem]:
        nonlocal budget_stopped, visited_nodes
        try:
            with os.scandir(directory_descriptor) as entries:
                for entry in entries:
                    if budget_stopped:
                        return
                    relative = f"{prefix}/{entry.name}" if prefix else entry.name
                    visited_nodes += 1
                    if visited_nodes > max_nodes or time.monotonic() >= deadline:
                        budget_stopped = True
                        yield InventoryItem(relative, entry.name, None, expected, "global-budget")
                        return
                    try:
                        info = entry.stat(follow_symlinks=False)
                    except OSError as error:
                        yield InventoryItem(relative, entry.name, None, expected, f"unobserved:{sanitize_reason(error)}")
                        continue
                    if excluded(relative, exclude_patterns):
                        yield InventoryItem(relative, entry.name, None, info, "excluded")
                    elif stat.S_ISLNK(info.st_mode):
                        yield InventoryItem(relative, entry.name, None, info, "symlink-not-followed")
                    elif stat.S_ISDIR(info.st_mode):
                        if depth >= max_depth:
                            yield InventoryItem(relative, entry.name, None, info, "depth-limit")
                            continue
                        try:
                            child_descriptor = os.open(entry.name, DIRECTORY_FLAGS, dir_fd=directory_descriptor)
                        except OSError as error:
                            yield InventoryItem(relative, entry.name, None, info, f"unobserved:{sanitize_reason(error)}")
                            continue
                        try:
                            child_info = os.fstat(child_descriptor)
                            if (child_info.st_dev, child_info.st_ino) != (info.st_dev, info.st_ino):
                                yield InventoryItem(relative, entry.name, None, info, "unobserved:directory changed")
                                continue
                            yield from visit(child_descriptor, relative, depth + 1)
                        finally:
                            os.close(child_descriptor)
                    elif stat.S_ISREG(info.st_mode):
                        yield from _open_file(entry.name, relative, directory_descriptor, info)
                    else:
                        yield InventoryItem(relative, entry.name, None, info, "non-regular-file")
        except OSError as error:
            relative = prefix or "."
            yield InventoryItem(relative, Path(prefix).name or ".", None, expected, f"unobserved:{sanitize_reason(error)}")

    try:
        yield from visit(root_descriptor, "", 0)
    finally:
        os.close(root_descriptor)


def _open_file(
    name: str, relative: str, directory_descriptor: int, expected: os.stat_result
) -> Iterator[InventoryItem]:
    try:
        file_descriptor = os.open(name, FILE_FLAGS, dir_fd=directory_descriptor)
    except OSError as error:
        yield InventoryItem(relative, name, None, expected, f"unobserved:{sanitize_reason(error)}")
        return
    try:
        opened = os.fstat(file_descriptor)
        if (opened.st_dev, opened.st_ino) != (expected.st_dev, expected.st_ino):
            yield InventoryItem(relative, name, None, expected, "unobserved:file changed")
            return
        yield InventoryItem(relative, name, file_descriptor, opened)
    finally:
        os.close(file_descriptor)


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
