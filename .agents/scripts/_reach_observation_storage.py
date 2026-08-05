#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Owner-only, descriptor-relative storage for Reach search observations."""

from __future__ import annotations

import hashlib
import json
import os
import secrets
import stat
from pathlib import Path
from typing import Any

from _reach_observation_read import (
    ObservationStorageError,
    load_json_object,
    read_private_file,
)

OBSERVATION_ID_KEY_BYTES = 32
OBSERVATION_ID_KEY_NAME = ".observation-id-key"


def _directory_flags() -> int:
    return (
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_DIRECTORY", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )


def _validate_private_directory(descriptor: int, label: str) -> None:
    directory_stat = os.fstat(descriptor)
    if not stat.S_ISDIR(directory_stat.st_mode):
        raise ObservationStorageError(f"{label} must be a directory")
    if hasattr(os, "getuid") and directory_stat.st_uid != os.getuid():
        raise ObservationStorageError(f"{label} owner must be the current user")
    if stat.S_IMODE(directory_stat.st_mode) & 0o077:
        raise ObservationStorageError(
            f"{label} must not grant group or other permissions"
        )


def _validated_directory_descriptor(descriptor: int, label: str) -> int:
    try:
        _validate_private_directory(descriptor, label)
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def open_private_directory(path: Path, label: str) -> int:
    """Open and validate an owner-only directory without following it."""
    try:
        return _validated_directory_descriptor(
            os.open(path, _directory_flags()), label
        )
    except ObservationStorageError:
        raise
    except OSError as error:
        raise ObservationStorageError(f"{label} is unavailable") from error


def open_private_child_directory(parent_fd: int, name: str, label: str) -> int:
    """Open an owner-only child relative to a pinned parent descriptor."""
    try:
        return _validated_directory_descriptor(
            os.open(name, _directory_flags(), dir_fd=parent_fd), label
        )
    except ObservationStorageError:
        raise
    except OSError as error:
        raise ObservationStorageError(f"{label} is unavailable") from error


def ensure_private_child_directory(parent_fd: int, name: str, label: str) -> int:
    """Create and durably publish an owner-only child directory if absent."""
    created = False
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        created = True
    except FileExistsError:
        pass
    except OSError as error:
        raise ObservationStorageError(f"{label} could not be created") from error
    descriptor = open_private_child_directory(parent_fd, name, label)
    if created:
        os.fsync(parent_fd)
    return descriptor


def _entry_exists(directory_fd: int, name: str) -> bool:
    try:
        os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
        return True
    except FileNotFoundError:
        return False


def _create_private_temporary(directory_fd: int, prefix: str) -> tuple[int, str]:
    flags = (
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
    )
    for _ in range(16):
        name = f".{prefix}-{secrets.token_hex(12)}"
        try:
            return os.open(name, flags, 0o600, dir_fd=directory_fd), name
        except FileExistsError:
            continue
    raise ObservationStorageError("private temporary file could not be allocated")


def _unlink_temporary(directory_fd: int, name: str) -> None:
    try:
        os.unlink(name, dir_fd=directory_fd)
        os.fsync(directory_fd)
    except FileNotFoundError:
        pass


def observation_id_key(workspace_fd: int) -> bytes:
    """Load or atomically create the workspace-local keyed-ID material."""
    if _entry_exists(workspace_fd, OBSERVATION_ID_KEY_NAME):
        key = read_private_file(
            OBSERVATION_ID_KEY_NAME,
            "observation ID key",
            OBSERVATION_ID_KEY_BYTES,
            workspace_fd,
        )
        if len(key) != OBSERVATION_ID_KEY_BYTES:
            raise ObservationStorageError("observation ID key size is invalid")
        os.fsync(workspace_fd)
        return key
    generated = secrets.token_bytes(OBSERVATION_ID_KEY_BYTES)
    descriptor, temporary = _create_private_temporary(workspace_fd, "observation-key")
    published = False
    try:
        with os.fdopen(descriptor, "wb") as target:
            os.fchmod(target.fileno(), 0o600)
            target.write(generated)
            target.flush()
            os.fsync(target.fileno())
        try:
            os.link(
                temporary,
                OBSERVATION_ID_KEY_NAME,
                src_dir_fd=workspace_fd,
                dst_dir_fd=workspace_fd,
                follow_symlinks=False,
            )
            published = True
            os.fsync(workspace_fd)
        except FileExistsError:
            pass
    finally:
        _unlink_temporary(workspace_fd, temporary)
    if published:
        return generated
    key = read_private_file(
        OBSERVATION_ID_KEY_NAME,
        "observation ID key",
        OBSERVATION_ID_KEY_BYTES,
        workspace_fd,
    )
    if len(key) != OBSERVATION_ID_KEY_BYTES:
        raise ObservationStorageError("observation ID key size is invalid")
    return key


def copy_evidence(
    payload: bytes,
    directory_fd: int,
    destination: str,
    expected_hash: str,
    maximum: int,
) -> None:
    """Publish validated evidence immutably beneath a pinned directory."""
    if _entry_exists(directory_fd, destination):
        stored = read_private_file(destination, "stored evidence", maximum, directory_fd)
        if hashlib.sha256(stored).hexdigest() != expected_hash:
            raise ObservationStorageError("stored evidence hash conflicts")
        os.fsync(directory_fd)
        return
    file_descriptor, temporary = _create_private_temporary(directory_fd, "evidence")
    try:
        with os.fdopen(file_descriptor, "wb") as target:
            os.fchmod(target.fileno(), 0o600)
            target.write(payload)
            target.flush()
            os.fsync(target.fileno())
        if hashlib.sha256(payload).hexdigest() != expected_hash:
            raise ObservationStorageError("evidence digest changed during recording")
        try:
            os.link(
                temporary,
                destination,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
            os.fsync(directory_fd)
        except FileExistsError:
            stored = read_private_file(
                destination, "stored evidence", maximum, directory_fd
            )
            if hashlib.sha256(stored).hexdigest() != expected_hash:
                raise ObservationStorageError("stored evidence hash conflicts")
    finally:
        _unlink_temporary(directory_fd, temporary)


def write_record(
    directory_fd: int,
    name: str,
    record: dict[str, Any],
    maximum: int,
) -> str:
    """Publish one replay-stable private observation record."""
    if _entry_exists(directory_fd, name):
        existing = load_json_object(name, "stored observation", maximum, directory_fd)
        existing_without_time = dict(existing)
        existing_without_time.pop("recorded_at", None)
        candidate_without_time = dict(record)
        candidate_without_time.pop("recorded_at", None)
        if existing_without_time != candidate_without_time:
            raise ObservationStorageError("stored observation identity conflicts")
        os.fsync(directory_fd)
        return "existing"
    file_descriptor, temporary = _create_private_temporary(
        directory_fd, "observation"
    )
    try:
        with os.fdopen(file_descriptor, "w", encoding="utf-8") as handle:
            os.fchmod(handle.fileno(), 0o600)
            json.dump(record, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        try:
            os.link(
                temporary,
                name,
                src_dir_fd=directory_fd,
                dst_dir_fd=directory_fd,
                follow_symlinks=False,
            )
            os.fsync(directory_fd)
        except FileExistsError:
            existing = load_json_object(
                name, "stored observation", maximum, directory_fd
            )
            existing.pop("recorded_at", None)
            candidate = dict(record)
            candidate.pop("recorded_at", None)
            if existing != candidate:
                raise ObservationStorageError("stored observation identity conflicts")
            return "existing"
    finally:
        _unlink_temporary(directory_fd, temporary)
    return "recorded"
