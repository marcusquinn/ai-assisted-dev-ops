#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Private filesystem and authentication-context primitives for corpora."""

from __future__ import annotations

import json
import os
import re
import stat
import uuid
from pathlib import Path

PRINCIPAL_PATTERN = re.compile(r"^prn_[0-9a-f]{32}$")
PRIVATE_DIRECTORY_MODE = 0o700
PRIVATE_FILE_MODE = 0o600


class CatalogError(RuntimeError):
    """A fail-closed catalog or authorization error."""


def _absolute_path(path: Path) -> Path:
    expanded = path.expanduser()
    if not expanded.is_absolute():
        expanded = Path.cwd() / expanded
    return expanded


def _lstat(path: Path, label: str) -> os.stat_result:
    try:
        return path.lstat()
    except FileNotFoundError as exc:
        raise CatalogError(f"{label} missing: {path}") from exc
    except OSError as exc:
        raise CatalogError(f"cannot inspect {label}: {path}") from exc


def _validate_owner(file_stat: os.stat_result, label: str) -> None:
    if hasattr(os, "getuid") and file_stat.st_uid != os.getuid():
        raise CatalogError(f"{label} owner does not match the current user")


def validate_directory(path: Path, label: str, *, repair: bool) -> Path:
    file_stat = _lstat(path, label)
    if stat.S_ISLNK(file_stat.st_mode):
        raise CatalogError(f"{label} symlink is not allowed")
    if not stat.S_ISDIR(file_stat.st_mode):
        raise CatalogError(f"{label} is not a directory: {path}")
    _validate_owner(file_stat, label)
    mode = stat.S_IMODE(file_stat.st_mode)
    if mode != PRIVATE_DIRECTORY_MODE:
        if not repair:
            raise CatalogError(f"{label} permissions must be 0700")
        os.chmod(path, PRIVATE_DIRECTORY_MODE)
    return path.resolve(strict=True)


def prepare_base(base: Path, *, create: bool) -> Path:
    absolute = _absolute_path(base)
    if create:
        absolute.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    return validate_directory(absolute, "knowledge base", repair=create)


def prepare_private_directory(path: Path, label: str) -> Path:
    path.mkdir(parents=True, exist_ok=True, mode=PRIVATE_DIRECTORY_MODE)
    return validate_directory(path, label, repair=True)


def validate_private_file(path: Path, label: str, *, repair: bool) -> None:
    file_stat = _lstat(path, label)
    if stat.S_ISLNK(file_stat.st_mode):
        raise CatalogError(f"{label} symlink is not allowed")
    if not stat.S_ISREG(file_stat.st_mode):
        raise CatalogError(f"{label} is not a regular file: {path}")
    _validate_owner(file_stat, label)
    mode = stat.S_IMODE(file_stat.st_mode)
    if mode != PRIVATE_FILE_MODE:
        if not repair:
            raise CatalogError(f"{label} permissions must be 0600")
        os.chmod(path, PRIVATE_FILE_MODE)


def prepare_catalog_file(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
        if hasattr(os, "O_NOFOLLOW"):
            flags |= os.O_NOFOLLOW
        descriptor = os.open(path, flags, PRIVATE_FILE_MODE)
        os.close(descriptor)
    validate_private_file(path, "catalog", repair=True)


def safe_location(base: Path, location_ref: str) -> Path:
    candidate = Path(location_ref)
    if not candidate.is_absolute():
        raise CatalogError("unsafe path: catalog location must be absolute")
    try:
        resolved = candidate.resolve(strict=True)
    except (FileNotFoundError, OSError) as exc:
        raise CatalogError("unsafe path: catalog location is unavailable") from exc
    if candidate != resolved:
        raise CatalogError("unsafe path: symlinks or non-canonical components are forbidden")
    try:
        resolved.relative_to(base)
    except ValueError as exc:
        raise CatalogError("unsafe path: catalog location escapes the knowledge base") from exc
    file_stat = _lstat(resolved, "corpus location")
    if stat.S_ISLNK(file_stat.st_mode) or not stat.S_ISDIR(file_stat.st_mode):
        raise CatalogError("unsafe path: corpus location must be a real directory")
    _validate_owner(file_stat, "corpus location")
    return resolved


def _context_payload(principal_id: str) -> dict[str, object]:
    return {"version": 1, "principal_id": principal_id}


def write_context_atomic(context_path: Path, principal_id: str) -> None:
    temporary = context_path.with_name(
        f".{context_path.name}.{uuid.uuid4().hex}.tmp"
    )
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(temporary, flags, PRIVATE_FILE_MODE)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            json.dump(_context_payload(principal_id), handle, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, context_path)
        os.chmod(context_path, PRIVATE_FILE_MODE)
        directory_flags = os.O_RDONLY
        if hasattr(os, "O_DIRECTORY"):
            directory_flags |= os.O_DIRECTORY
        directory_fd = os.open(context_path.parent, directory_flags)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        if temporary.exists():
            temporary.unlink()


def _read_context_file(context_path: Path) -> dict[str, object]:
    before = _lstat(context_path, "authentication context")
    if stat.S_ISLNK(before.st_mode):
        raise CatalogError("context symlink is not allowed")
    if not stat.S_ISREG(before.st_mode):
        raise CatalogError("malformed context: expected a regular file")
    _validate_owner(before, "authentication context")
    if stat.S_IMODE(before.st_mode) != PRIVATE_FILE_MODE:
        raise CatalogError("context permissions must be 0600")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        descriptor = os.open(context_path, flags)
    except OSError as exc:
        raise CatalogError("context symlink or replacement detected") from exc
    with os.fdopen(descriptor, "r", encoding="utf-8") as handle:
        after = os.fstat(handle.fileno())
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            raise CatalogError("context replacement detected")
        try:
            payload = json.load(handle)
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise CatalogError("malformed context: invalid JSON") from exc
    if not isinstance(payload, dict):
        raise CatalogError("malformed context: expected an object")
    return payload


def load_principal(context_path: Path) -> str:
    payload = _read_context_file(context_path)
    if set(payload) != {"version", "principal_id"} or payload.get("version") != 1:
        raise CatalogError("malformed context: unsupported fields or version")
    principal_id = payload.get("principal_id")
    if not isinstance(principal_id, str) or not PRINCIPAL_PATTERN.fullmatch(
        principal_id
    ):
        raise CatalogError("malformed context: invalid principal ID")
    return principal_id
