#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Owner-only snapshot readers for private Reach observation files."""

from __future__ import annotations

import json
import os
import stat
from pathlib import Path
from typing import Any


class ObservationStorageError(ValueError):
    """Raised when private observation storage is unsafe or inconsistent."""


def _path_stat(path: str, directory_fd: int | None) -> os.stat_result:
    if directory_fd is None:
        return os.lstat(path)
    return os.stat(path, dir_fd=directory_fd, follow_symlinks=False)


def _open_readonly(path: str, directory_fd: int | None) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    if directory_fd is None:
        return os.open(path, flags)
    return os.open(path, flags, dir_fd=directory_fd)


def _validate_private_file(file_stat: os.stat_result, label: str, maximum: int) -> None:
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise ObservationStorageError(f"{label} must be a regular non-symlink file")
    if hasattr(os, "getuid") and file_stat.st_uid != os.getuid():
        raise ObservationStorageError(f"{label} owner must be the current user")
    if stat.S_IMODE(file_stat.st_mode) & 0o077:
        raise ObservationStorageError(
            f"{label} must not grant group or other permissions"
        )
    if file_stat.st_size <= 0 or file_stat.st_size > maximum:
        raise ObservationStorageError(f"{label} size is outside the allowed limit")


def _file_identity(file_stat: os.stat_result) -> tuple[int, int, int, int]:
    return (
        file_stat.st_dev,
        file_stat.st_ino,
        file_stat.st_size,
        file_stat.st_mtime_ns,
    )


def read_private_file(
    path: str | Path,
    label: str,
    maximum: int,
    directory_fd: int | None = None,
) -> bytes:
    """Read one immutable snapshot without following a final symlink."""
    descriptor = -1
    path_value = os.fspath(path)
    try:
        path_stat = _path_stat(path_value, directory_fd)
        _validate_private_file(path_stat, label, maximum)
        descriptor = _open_readonly(path_value, directory_fd)
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            opened = os.fstat(handle.fileno())
            _validate_private_file(opened, label, maximum)
            if (path_stat.st_dev, path_stat.st_ino) != (opened.st_dev, opened.st_ino):
                raise ObservationStorageError(f"{label} changed while opening")
            payload = handle.read(maximum + 1)
            after = os.fstat(handle.fileno())
    except ObservationStorageError:
        raise
    except OSError as error:
        raise ObservationStorageError(f"{label} is unavailable") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if (
        len(payload) > maximum
        or len(payload) != opened.st_size
        or _file_identity(opened) != _file_identity(after)
    ):
        raise ObservationStorageError(f"{label} changed while being read")
    return payload


def load_json_object(
    path: str | Path,
    label: str,
    maximum: int,
    directory_fd: int | None = None,
) -> dict[str, Any]:
    """Load a private UTF-8 JSON object from one validated snapshot."""
    try:
        value = json.loads(
            read_private_file(path, label, maximum, directory_fd).decode("utf-8")
        )
    except (UnicodeError, json.JSONDecodeError) as error:
        raise ObservationStorageError(f"{label} must be valid UTF-8 JSON") from error
    if not isinstance(value, dict):
        raise ObservationStorageError(f"{label} root must be an object")
    return value
