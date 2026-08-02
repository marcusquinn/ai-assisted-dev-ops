#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Crash-consistent writes of immutable social raw evidence."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import sqlite3
import uuid
from dataclasses import dataclass
from pathlib import Path
from types import TracebackType

from _knowledge_social_store_raw_fs import (
    _fsync_directory,
    _unlink_private_file,
    _validate_raw_file,
    _validated_directory,
    _write_private_file,
    private_directory,
    validate_opaque,
)
from _knowledge_social_store_support import SocialStoreError

_STAGING_DIRECTORY = Path("sources") / "social" / "raw" / ".staging"
_TEST_FAULT_ENV = "AIDEVOPS_SOCIAL_RAW_TEST_FAULT"


@dataclass(frozen=True)
class _StagedRawBatch:
    root: Path
    provider: str
    connection_id: str
    digest: str
    blob_ref: str
    path: Path
    marker_path: Path
    staging_path: Path
    created: bool


def _raw_location(
    root: Path, provider: str, connection_id: str, payload: bytes
) -> tuple[Path, str, Path, str]:
    provider = validate_opaque(provider, "provider")
    connection_id = validate_opaque(connection_id, "connection_id")
    root = _validated_directory(root, "social corpus root", repair=False)
    digest = hashlib.sha256(payload).hexdigest()
    relative = (
        Path("sources")
        / "social"
        / "raw"
        / provider
        / connection_id
        / f"{digest}.json.gz"
    )
    directory = private_directory(root, relative.parent)
    path = directory / relative.name
    return root, digest, path, relative.as_posix()


def _write_marker(
    staging_directory: Path, token: str, digest: str, blob_ref: str
) -> Path:
    marker_path = staging_directory / f"{token}.json"
    marker = json.dumps(
        {"version": 1, "token": token, "digest": digest, "blob_ref": blob_ref},
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    _write_private_file(marker_path, marker)
    _fsync_directory(staging_directory)
    return marker_path


def _link_staged_file(staging_path: Path, path: Path) -> bool:
    try:
        os.link(staging_path, path, follow_symlinks=False)
    except FileExistsError:
        return False
    except OSError as error:
        raise SocialStoreError("social raw evidence could not be published") from error
    _fsync_directory(path.parent)
    return True


def _stage_raw_batch(
    root: Path, provider: str, connection_id: str, payload: bytes
) -> _StagedRawBatch:
    root, digest, path, blob_ref = _raw_location(
        root, provider, connection_id, payload
    )
    staging_directory = private_directory(root, _STAGING_DIRECTORY)
    token = uuid.uuid4().hex
    marker_path = _write_marker(staging_directory, token, digest, blob_ref)
    staging_path = staging_directory / f"{token}.stage"
    created = False
    try:
        compressed = gzip.compress(payload, compresslevel=9, mtime=0)
        _write_private_file(staging_path, compressed)
        created = _link_staged_file(staging_path, path)
        if not created:
            _validate_raw_file(root, blob_ref, digest)
        _unlink_private_file(staging_path)
        return _StagedRawBatch(
            root,
            provider,
            connection_id,
            digest,
            blob_ref,
            path,
            marker_path,
            staging_path,
            created,
        )
    except Exception:
        try:
            _unlink_private_file(staging_path)
            if created:
                _unlink_private_file(path)
            _unlink_private_file(marker_path)
        except (OSError, SocialStoreError):
            pass
        raise


def _finish_stage(staged: _StagedRawBatch) -> None:
    _unlink_private_file(staged.staging_path)
    _unlink_private_file(staged.marker_path)


def _discard_stage(staged: _StagedRawBatch) -> None:
    if staged.created and (staged.path.exists() or staged.path.is_symlink()):
        _validate_raw_file(staged.root, staged.blob_ref, staged.digest)
        _unlink_private_file(staged.path)
    _finish_stage(staged)


def write_raw_batch(
    root: Path, provider: str, connection_id: str, payload: bytes
) -> tuple[str, str]:
    """Durably write one immutable blob outside a database transaction.

    Production fetch-batch writers must use :func:`raw_evidence_transaction` so
    the durable blob and its SQLite reference share the recovery lifecycle.
    """
    staged = _stage_raw_batch(root, provider, connection_id, payload)
    _finish_stage(staged)
    return staged.digest, staged.blob_ref


def _apply_test_fault() -> None:
    if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        return
    fault = os.environ.get(_TEST_FAULT_ENV)
    if fault == "raise-after-durable":
        raise SocialStoreError("injected failure after durable social raw write")
    if fault == "exit-after-durable":
        os._exit(86)
    if fault:
        raise SocialStoreError("social raw test fault is invalid")


class RawEvidenceTransaction:
    """Commit raw files before SQLite and clean rollback debris safely.

    The transaction holds SQLite's immediate-writer lock while staging every
    blob. Each blob and its parent entry are durable before a matching
    ``fetch_batches.blob_ref`` can commit. A durable marker protects a killed
    writer until recovery's age boundary; committed references always win.
    """

    def __init__(self, connection: sqlite3.Connection, root: Path) -> None:
        self.connection = connection
        self.root = root
        self._staged: list[_StagedRawBatch] = []
        self._entered = False

    def __enter__(self) -> RawEvidenceTransaction:
        if self.connection.in_transaction:
            raise SocialStoreError("raw evidence transaction requires autocommit state")
        self.connection.execute("BEGIN IMMEDIATE")
        self._entered = True
        return self

    def write(
        self, provider: str, connection_id: str, payload: bytes
    ) -> tuple[str, str]:
        if not self._entered or not self.connection.in_transaction:
            raise SocialStoreError("raw evidence write requires an active transaction")
        staged = _stage_raw_batch(self.root, provider, connection_id, payload)
        self._staged.append(staged)
        _apply_test_fault()
        return staged.digest, staged.blob_ref

    def _validate_references(self) -> None:
        for staged in self._staged:
            rows = self.connection.execute(
                "SELECT provider,connection_id FROM fetch_batches WHERE blob_ref=?",
                (staged.blob_ref,),
            ).fetchall()
            if not any(
                row["provider"] == staged.provider
                and row["connection_id"] == staged.connection_id
                for row in rows
            ):
                raise SocialStoreError(
                    "raw evidence transaction has no matching fetch batch"
                )
            _validate_raw_file(staged.root, staged.blob_ref, staged.digest)

    def _rollback(self) -> None:
        if not self.connection.in_transaction:
            return
        for staged in reversed(self._staged):
            try:
                _discard_stage(staged)
            except (OSError, SocialStoreError):
                pass
        self.connection.execute("ROLLBACK")

    def __exit__(
        self,
        exception_type: type[BaseException] | None,
        exception: BaseException | None,
        traceback: TracebackType | None,
    ) -> bool:
        del exception, traceback
        if exception_type is not None:
            self._rollback()
            return False
        try:
            self._validate_references()
            self.connection.execute("COMMIT")
        except BaseException:
            self._rollback()
            raise
        for staged in self._staged:
            try:
                _finish_stage(staged)
            except (OSError, SocialStoreError):
                # SQLite is already committed, so marker cleanup cannot turn a
                # successful durable write into an ambiguous caller failure.
                # Recovery removes any marker or partial cleanup left behind.
                pass
        return False


def raw_evidence_transaction(
    connection: sqlite3.Connection, root: Path
) -> RawEvidenceTransaction:
    return RawEvidenceTransaction(connection, root)
