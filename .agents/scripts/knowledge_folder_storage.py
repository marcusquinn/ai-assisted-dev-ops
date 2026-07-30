#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Raw payload and lock primitives for recursive folder ingestion."""

from __future__ import annotations

import fcntl
import os
import shutil
import tempfile
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Iterator

from knowledge_folder_model import EvidenceInput, EvidenceProcessingError, StoredBlob
from knowledge_folder_types import fsync_directory, sha256_bytes, sha256_file


class StorageMixin:
    """Provide digest locking and external large-blob storage."""

    @contextmanager
    def _digest_lock(self, digest: str) -> Iterator[None]:
        lock_dir = _secure_directory(self.index_dir, "folder-imports", "digest-locks")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(lock_dir / f"{digest}.lock", flags, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def _store_blob(self, source_id: str, evidence: EvidenceInput) -> StoredBlob:
        blob_root = _secure_directory(
            Path.home(), ".aidevops", ".agent-workspace", "knowledge-blobs",
            self._blob_namespace(),
        )
        blob_dir = _secure_directory(blob_root, source_id)
        destination = blob_dir / "raw.bin"
        if destination.exists() or destination.is_symlink():
            if destination.is_symlink() or not destination.is_file() or sha256_file(destination) != evidence.digest:
                raise EvidenceProcessingError("existing blob payload is unsafe or inconsistent")
            return StoredBlob(f"knowledge-blobs:sha256:{evidence.digest}", destination, False)
        _write_payload(destination, evidence.descriptor, evidence.data)
        if sha256_file(destination) != evidence.digest:
            destination.unlink(missing_ok=True)
            raise EvidenceProcessingError("stored blob digest does not match inventory")
        fsync_directory(blob_dir)
        return StoredBlob(f"knowledge-blobs:sha256:{evidence.digest}", destination, True)

    def _blob_namespace(self) -> str:
        root_digest = sha256_bytes(str(self.knowledge_root.resolve()).encode("utf-8"))
        return f"folder-imports-{root_digest[:16]}"


def _read_descriptor(descriptor: int) -> bytes:
    duplicate = os.dup(descriptor)
    try:
        os.lseek(duplicate, 0, os.SEEK_SET)
        with os.fdopen(duplicate, "rb", closefd=True) as handle:
            duplicate = -1
            return handle.read()
    finally:
        if duplicate >= 0:
            os.close(duplicate)


def _write_payload(path: Path, source_descriptor: int | None, data: bytes | None) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as target:
            descriptor = -1
            _write_payload_content(target, source_descriptor, data)
            target.flush()
            os.fsync(target.fileno())
        temporary.replace(path)
        fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _write_payload_content(target: object, source_descriptor: int | None, data: bytes | None) -> None:
    if source_descriptor is None:
        target.write(data or b"")
        return
    duplicate = os.dup(source_descriptor)
    try:
        os.lseek(duplicate, 0, os.SEEK_SET)
        with os.fdopen(duplicate, "rb", closefd=True) as source:
            duplicate = -1
            shutil.copyfileobj(source, target, 1024 * 1024)
    finally:
        if duplicate >= 0:
            os.close(duplicate)


def _remove_blob(path: Path) -> None:
    try:
        path.unlink(missing_ok=True)
        path.parent.rmdir()
    except OSError:
        pass
    try:
        if path.parent.parent.is_dir():
            fsync_directory(path.parent.parent)
    except OSError:
        pass


def _secure_directory(base: Path, *components: str, create: bool = True) -> Path:
    if base.is_symlink() or not base.is_dir():
        raise EvidenceProcessingError("storage root is unsafe")
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
            raise EvidenceProcessingError("storage directory is unsafe")
    return current


def _utc_now() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
