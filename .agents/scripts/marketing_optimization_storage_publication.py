#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Pinned-file primitives for immutable optimization publication."""

from __future__ import annotations

import os
import secrets
import stat
from collections.abc import Callable
from dataclasses import dataclass

from marketing_optimization_contract import OptimizationError

MAX_OUTPUT_BYTES = 16 * 1024 * 1024


@dataclass(frozen=True)
class TemporaryWriteRequest:
    """Dependencies and payload for one pinned temporary write."""

    directory_fd: int
    prefix: str
    payload: bytes
    create: Callable[[int, str], tuple[int, str]]
    unlink: Callable[[int, str], None]
    mode: int


def stored_payload(directory_fd: int, name: str) -> bytes | None:
    """Read one pinned regular output without following a final symlink."""
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise OptimizationError("immutable optimization output conflicts") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > MAX_OUTPUT_BYTES:
            raise OptimizationError("immutable optimization output conflicts")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            return handle.read()
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def create_temporary(directory_fd: int, prefix: str) -> tuple[int, str]:
    """Allocate one exclusive temporary file beneath a pinned directory."""
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
    for _ in range(16):
        name = f".{prefix}.{secrets.token_hex(12)}"
        try:
            return os.open(name, flags, 0o600, dir_fd=directory_fd), name
        except FileExistsError:
            continue
    raise OptimizationError("optimization temporary file allocation failed")


def unlink_entry(directory_fd: int, name: str) -> None:
    """Durably remove one descriptor-relative temporary entry."""
    try:
        os.unlink(name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except FileNotFoundError:
        pass


def write_temporary(request: TemporaryWriteRequest) -> tuple[int, str]:
    """Write and synchronize one temporary payload while retaining its descriptor."""
    descriptor, name = request.create(request.directory_fd, request.prefix)
    try:
        os.fchmod(descriptor, request.mode)
        with os.fdopen(os.dup(descriptor), "wb") as handle:
            handle.write(request.payload)
            handle.flush()
            os.fsync(handle.fileno())
        return descriptor, name
    except Exception:
        os.close(descriptor)
        request.unlink(request.directory_fd, name)
        raise


def descriptor_matches_entry(descriptor: int, directory_fd: int, name: str) -> bool:
    """Return whether a pinned descriptor still identifies one regular entry."""
    try:
        descriptor_stat = os.fstat(descriptor)
        entry_stat = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
    except OSError:
        return False
    regular = stat.S_ISREG(descriptor_stat.st_mode) and stat.S_ISREG(entry_stat.st_mode)
    same_inode = (descriptor_stat.st_dev, descriptor_stat.st_ino) == (entry_stat.st_dev, entry_stat.st_ino)
    return regular and same_inode


def publish_temporary(
    directory_fd: int,
    descriptor: int,
    temporary: str,
    destination: str,
    payload: bytes,
) -> bool:
    """Link one payload exactly once and verify a concurrent winner."""
    try:
        os.link(
            temporary,
            destination,
            src_dir_fd=directory_fd,
            dst_dir_fd=directory_fd,
            follow_symlinks=False,
        )
        os.fsync(directory_fd)
        checks = (
            descriptor_matches_entry(descriptor, directory_fd, destination),
            stored_payload(directory_fd, destination) == payload,
            descriptor_matches_entry(descriptor, directory_fd, destination),
        )
        if not all(checks):
            unlink_entry(directory_fd, destination)
            raise OptimizationError("optimization temporary changed during publication")
        return True
    except FileExistsError:
        if stored_payload(directory_fd, destination) != payload:
            raise OptimizationError("immutable optimization output conflicts") from None
        return False
