#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Descriptor-relative immutable storage for marketing optimization artifacts."""

from __future__ import annotations

import os
import stat
from dataclasses import dataclass
from pathlib import Path

from marketing_optimization_contract import OptimizationError
from marketing_optimization_storage_publication import (
    MAX_OUTPUT_BYTES,
    TemporaryWriteRequest,
    create_temporary,
    descriptor_matches_entry,
    publish_temporary,
    stored_payload,
    unlink_entry,
    write_temporary,
)


@dataclass(frozen=True)
class ImmutablePublication:
    """Target, payload, and modes for one immutable publication."""

    root: Path
    path: Path
    payload: bytes
    file_mode: int = 0o644
    directory_mode: int = 0o755


def _relative_parts(root: Path, target: Path) -> tuple[str, ...]:
    """Return a repository-relative path without traversal components."""
    try:
        relative = Path(os.path.abspath(target)).relative_to(Path(os.path.abspath(root)))
    except ValueError as exc:
        raise OptimizationError("optimization path escapes its repository") from exc
    if any(component in {"", ".", ".."} for component in relative.parts):
        raise OptimizationError("optimization path contains an unsafe component")
    return relative.parts


def _directory_flags() -> int:
    """Return descriptor flags that refuse the final symlink component."""
    return os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_DIRECTORY | os.O_NOFOLLOW


def _open_directory_fd(root: Path, directory: Path, *, create: bool) -> int:
    """Open a repository directory through pinned descriptor-relative components."""
    components = _relative_parts(root, directory)
    descriptor = -1
    try:
        descriptor = os.open(root, _directory_flags())
        for component in components:
            if create:
                try:
                    os.mkdir(component, 0o755, dir_fd=descriptor)
                    os.fsync(descriptor)
                except FileExistsError:
                    pass
            child = os.open(component, _directory_flags(), dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise OptimizationError("optimization destination is not a directory")
        return descriptor
    except OptimizationError:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    except OSError as exc:
        if descriptor >= 0:
            os.close(descriptor)
        raise OptimizationError("optimization directory is unsafe or unavailable") from exc


def ensure_directory(root: Path, directory: Path, mode: int = 0o755) -> None:
    """Create and pin one repository directory without following symlinks."""
    descriptor = _open_directory_fd(root, directory, create=True)
    try:
        os.fchmod(descriptor, mode)
    finally:
        os.close(descriptor)


def _stored_payload(directory_fd: int, name: str) -> bytes | None:
    """Read one pinned regular output without following a final symlink."""
    return stored_payload(directory_fd, name)


def _create_temporary(directory_fd: int, prefix: str) -> tuple[int, str]:
    """Allocate one exclusive temporary file beneath a pinned directory."""
    return create_temporary(directory_fd, prefix)


def _unlink_entry(directory_fd: int, name: str) -> None:
    """Durably remove one descriptor-relative temporary entry."""
    unlink_entry(directory_fd, name)


def _write_temporary(directory_fd: int, prefix: str, payload: bytes, mode: int) -> tuple[int, str]:
    """Write and synchronize one temporary payload while retaining its descriptor."""
    request = TemporaryWriteRequest(directory_fd, prefix, payload, _create_temporary, _unlink_entry, mode)
    return write_temporary(request)


def _descriptor_matches_entry(descriptor: int, directory_fd: int, name: str) -> bool:
    """Return whether a pinned descriptor still identifies one directory entry."""
    return descriptor_matches_entry(descriptor, directory_fd, name)


def _set_entry_mode(directory_fd: int, name: str, mode: int) -> None:
    """Apply the declared mode through a no-follow regular-file descriptor."""
    descriptor = -1
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW,
            dir_fd=directory_fd,
        )
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise OptimizationError("immutable optimization output conflicts")
        os.fchmod(descriptor, mode)
    except OSError as exc:
        raise OptimizationError("immutable optimization output conflicts") from exc
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def _publish_temporary(
    directory_fd: int,
    descriptor: int,
    temporary: str,
    destination: str,
    payload: bytes,
) -> bool:
    """Link one payload exactly once and verify a concurrent winner."""
    return publish_temporary(
        directory_fd,
        descriptor,
        temporary,
        destination,
        payload,
    )


def _directory_binding_matches(root: Path, directory: Path, descriptor: int) -> bool:
    """Check that the public path still names the pinned output directory."""
    try:
        current = _open_directory_fd(root, directory, create=False)
    except OptimizationError:
        return False
    try:
        pinned_stat = os.fstat(descriptor)
        current_stat = os.fstat(current)
        return (pinned_stat.st_dev, pinned_stat.st_ino) == (current_stat.st_dev, current_stat.st_ino)
    finally:
        os.close(current)


def read_optional_bytes(root: Path, path: Path) -> bytes | None:
    """Read an optional immutable output through a pinned descriptor-relative path."""
    directory_fd = _open_directory_fd(root, path.parent, create=False)
    try:
        payload = _stored_payload(directory_fd, path.name)
        if not _directory_binding_matches(root, path.parent, directory_fd):
            raise OptimizationError("optimization source changed during read")
        return payload
    finally:
        os.close(directory_fd)


def read_bytes(root: Path, path: Path) -> bytes:
    """Read one required immutable output through a pinned descriptor-relative path."""
    payload = read_optional_bytes(root, path)
    if payload is None:
        raise OptimizationError("registered optimization artifact is unavailable")
    return payload


def immutable_bytes(publication: ImmutablePublication) -> Path:
    """Publish bytes once beneath a pinned, race-safe repository directory."""
    root = publication.root
    path = publication.path
    payload = publication.payload
    file_mode = publication.file_mode
    directory_mode = publication.directory_mode
    if len(payload) > MAX_OUTPUT_BYTES:
        raise OptimizationError("immutable optimization output exceeds the size limit")
    directory_fd = _open_directory_fd(root, path.parent, create=True)
    temporary_fd = -1
    temporary = ""
    published = False
    try:
        os.fchmod(directory_fd, directory_mode)
        existing = _stored_payload(directory_fd, path.name)
        if existing is not None:
            if existing != payload:
                raise OptimizationError("immutable optimization output conflicts")
        else:
            temporary_fd, temporary = _write_temporary(directory_fd, path.name, payload, file_mode)
            published = _publish_temporary(
                directory_fd,
                temporary_fd,
                temporary,
                path.name,
                payload,
            )
        _set_entry_mode(directory_fd, path.name, file_mode)
        if not _directory_binding_matches(root, path.parent, directory_fd):
            if published and temporary_fd >= 0 and _descriptor_matches_entry(temporary_fd, directory_fd, path.name):
                _unlink_entry(directory_fd, path.name)
            raise OptimizationError("optimization destination changed during publication")
        return path
    except OptimizationError:
        raise
    except OSError as exc:
        raise OptimizationError("immutable optimization publication failed") from exc
    finally:
        if temporary_fd >= 0:
            os.close(temporary_fd)
        if temporary:
            _unlink_entry(directory_fd, temporary)
        os.close(directory_fd)
