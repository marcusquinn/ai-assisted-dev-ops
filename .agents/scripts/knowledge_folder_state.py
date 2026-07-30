#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Confinement, limits, and scan leases for folder knowledge ingestion."""

from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path


DIRECTORY_FLAGS = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)


class FolderWalkError(ValueError):
    """Traversal or lease state cannot preserve scan confinement."""


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


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
