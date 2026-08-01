#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Owner-only durable filesystem primitives for social raw evidence."""

from __future__ import annotations

import gzip
import hashlib
import os
import stat
from pathlib import Path

from _knowledge_social_store_raw import _validated_raw_ref
from _knowledge_social_store_support import OPAQUE_ID, SocialStoreError
from knowledge_corpus_context import (
    CatalogError,
    validate_directory,
    validate_private_file,
)


def _validated_directory(path: Path, label: str, *, repair: bool) -> Path:
    try:
        return validate_directory(path, label, repair=repair)
    except CatalogError as error:
        raise SocialStoreError(str(error)) from error


def _validated_private_file(path: Path, label: str) -> None:
    try:
        validate_private_file(path, label, repair=False)
    except CatalogError as error:
        raise SocialStoreError(str(error)) from error


def _fsync_directory(path: Path) -> None:
    _validated_directory(path, "social store directory", repair=False)
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise SocialStoreError("social store directory changed while opening")
        os.fsync(descriptor)
    except OSError as error:
        raise SocialStoreError("social store directory could not be synchronized") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def private_directory(root: Path, relative: Path) -> Path:
    """Create owner-only components and durably record every new directory."""
    if relative.is_absolute() or any(part in ("", ".", "..") for part in relative.parts):
        raise SocialStoreError("social store directory path is invalid")
    directory = _validated_directory(root, "social corpus root", repair=False)
    for component in relative.parts:
        parent = directory
        directory = parent / component
        created = False
        try:
            directory.mkdir(mode=0o700)
            created = True
        except FileExistsError:
            pass
        except OSError as error:
            raise SocialStoreError("social store directory could not be created") from error
        directory = _validated_directory(
            directory, "social store directory", repair=True
        )
        if created:
            _fsync_directory(parent)
    return directory


def validate_opaque(value: str, field: str) -> str:
    if not OPAQUE_ID.fullmatch(value):
        raise SocialStoreError(f"{field} must be an opaque identifier")
    return value


def _exclusive_flags() -> int:
    return (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )


def _write_private_file(path: Path, payload: bytes) -> None:
    descriptor = -1
    created = False
    try:
        descriptor = os.open(path, _exclusive_flags(), 0o600)
        created = True
        with os.fdopen(descriptor, "wb") as target:
            descriptor = -1
            target.write(payload)
            target.flush()
            os.fsync(target.fileno())
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        if created:
            try:
                path.unlink(missing_ok=True)
                _fsync_directory(path.parent)
            except (OSError, SocialStoreError):
                pass
        raise


def _unlink_private_file(path: Path) -> bool:
    try:
        file_stat = path.lstat()
    except FileNotFoundError:
        return False
    except OSError as error:
        raise SocialStoreError("social raw evidence could not be inspected") from error
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISREG(file_stat.st_mode):
        raise SocialStoreError("social raw evidence cleanup refused an unsafe path")
    try:
        path.unlink()
        _fsync_directory(path.parent)
    except OSError as error:
        raise SocialStoreError("social raw evidence could not be removed") from error
    return True


def _raw_payload_digest(root: Path, relative: Path) -> str:
    raw_root = root / "sources" / "social" / "raw"
    path = root / relative
    descriptor = -1
    try:
        resolved = path.resolve(strict=True)
        if resolved != Path(os.path.abspath(path)):
            raise SocialStoreError("social raw evidence contains a symlink")
        resolved.relative_to(raw_root.resolve(strict=True))
        _validated_directory(
            path.parent.parent, "social raw provider directory", repair=False
        )
        _validated_directory(
            path.parent, "social raw connection directory", repair=False
        )
        _validated_private_file(path, "social raw evidence")
        before = path.lstat()
        flags = (
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0)
        )
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as raw:
            descriptor = -1
            opened = os.fstat(raw.fileno())
            if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                raise SocialStoreError("social raw evidence changed while opening")
            digest = hashlib.sha256()
            with gzip.GzipFile(fileobj=raw, mode="rb") as source:
                while chunk := source.read(1024 * 1024):
                    digest.update(chunk)
    except SocialStoreError:
        raise
    except (OSError, EOFError, ValueError) as error:
        raise SocialStoreError("social raw evidence could not be verified") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest()


def _validate_raw_file(root: Path, blob_ref: str, digest: str) -> None:
    relative, _, _, filename = _validated_raw_ref(blob_ref)
    if filename != f"{digest}.json.gz":
        raise SocialStoreError("immutable raw batch path does not match its hash")
    if _raw_payload_digest(root, relative) != digest:
        raise SocialStoreError("immutable raw batch hash mismatch")
