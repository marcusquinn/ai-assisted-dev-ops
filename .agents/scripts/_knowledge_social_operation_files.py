#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Race-resistant private-file readers for outbound social operations."""

from __future__ import annotations

import hashlib
import os
from pathlib import Path

from knowledge_corpus_context import CatalogError, validate_private_file

MAX_PAYLOAD_BYTES = 16 * 1024
MAX_MEDIA_BYTES = 2 * 1024**3


class OperationFileError(RuntimeError):
    """Raised when a private outbound input cannot be read safely."""


def _open_private_body(path: Path) -> tuple[int, os.stat_result]:
    try:
        validate_private_file(path, "outbound body", repair=False)
        before = path.lstat()
        flags = os.O_RDONLY
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags)
    except (CatalogError, OSError) as error:
        raise OperationFileError("outbound body is unavailable or unsafe") from error
    return descriptor, before


def _read_private_bytes(descriptor: int, before: os.stat_result) -> bytes:
    try:
        after = os.fstat(descriptor)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise OperationFileError("outbound body replacement detected")
        with os.fdopen(descriptor, "rb") as handle:
            descriptor = -1
            payload = handle.read(MAX_PAYLOAD_BYTES + 1)
    except OSError as error:
        raise OperationFileError("outbound body is unavailable or unsafe") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return payload


def read_private_body(path: Path) -> str:
    """Read one bounded UTF-8 body after validating its private-file identity."""
    descriptor, before = _open_private_body(path)
    payload = _read_private_bytes(descriptor, before)
    if len(payload) > MAX_PAYLOAD_BYTES:
        raise OperationFileError("outbound body exceeds the private payload limit")
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError as error:
        raise OperationFileError("outbound body must be UTF-8") from error


def read_private_subject(path: Path) -> str:
    """Read a private title and remove at most one trailing line ending."""
    subject = read_private_body(path)
    if subject.endswith("\n"):
        subject = subject[:-1]
        if subject.endswith("\r"):
            subject = subject[:-1]
    return subject


def _validated_media_path(path: Path) -> tuple[Path, os.stat_result]:
    try:
        validate_private_file(path, "outbound media", repair=False)
        resolved = path.resolve(strict=True)
        before = resolved.stat()
    except (CatalogError, OSError) as error:
        raise OperationFileError("outbound media is unavailable or unsafe") from error
    if not resolved.is_file() or not 1 <= before.st_size <= MAX_MEDIA_BYTES:
        raise OperationFileError("outbound media is unavailable or outside the size limit")
    return resolved, before


def private_media_digest(path: Path) -> tuple[str, str]:
    """Return an absolute private media path and a bounded streaming digest."""
    resolved, before = _validated_media_path(path)
    digest = hashlib.sha256()
    try:
        with resolved.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                digest.update(chunk)
        after = resolved.stat()
    except OSError as error:
        raise OperationFileError("outbound media is unavailable or unsafe") from error
    if (before.st_dev, before.st_ino, before.st_size) != (
        after.st_dev,
        after.st_ino,
        after.st_size,
    ):
        raise OperationFileError("outbound media replacement detected")
    return str(resolved), digest.hexdigest()
