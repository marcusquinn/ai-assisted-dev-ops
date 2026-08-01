#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Safe lease-aware recovery of unreferenced social raw evidence."""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path

from _knowledge_social_store_raw_fs import (
    _unlink_private_file,
    _validate_raw_file,
    _validated_directory,
)
from _knowledge_social_store_raw_inventory import (
    _RecoveryMarker,
    _is_old,
    _raw_inventory,
    _referenced_raw_files,
    _staging_inventory,
)
from _knowledge_social_store_support import SocialStoreError

RAW_RECOVERY_GRACE_SECONDS = 24 * 60 * 60


@dataclass(frozen=True)
class RawEvidenceRecovery:
    """Counts returned by one idempotent raw-evidence recovery pass."""

    orphan_files_removed: int = 0
    corrupt_files_removed: int = 0
    staging_files_removed: int = 0
    markers_removed: int = 0
    protected_files: int = 0


def _validate_references(
    root: Path,
    references: set[str],
    inventory: dict[str, Path],
    verify_referenced: bool,
) -> None:
    if references - set(inventory):
        raise SocialStoreError("committed fetch batch raw evidence is missing")
    if not verify_referenced:
        return
    for blob_ref in references:
        digest = Path(blob_ref).name.removesuffix(".json.gz")
        _validate_raw_file(root, blob_ref, digest)


def _recover_orphan_files(
    root: Path,
    inventory: dict[str, Path],
    references: set[str],
    active_refs: set[str],
    cutoff: float,
) -> tuple[int, int, int]:
    removed = 0
    corrupt = 0
    protected = 0
    for blob_ref, path in inventory.items():
        if blob_ref in references or blob_ref in active_refs or not _is_old(path, cutoff):
            protected += 1
            continue
        digest = path.name.removesuffix(".json.gz")
        try:
            _validate_raw_file(root, blob_ref, digest)
        except SocialStoreError:
            corrupt += 1
        _unlink_private_file(path)
        removed += 1
    return removed, corrupt, protected


def _recover_staging_files(
    staged_files: dict[str, Path],
    markers: dict[str, _RecoveryMarker],
    cutoff: float,
) -> tuple[int, int]:
    removed = 0
    protected = 0
    for token, path in staged_files.items():
        marker = markers.get(token)
        marker_active = marker is not None and marker.modified_at > cutoff
        if marker_active or not _is_old(path, cutoff):
            protected += 1
            continue
        _unlink_private_file(path)
        removed += 1
    return removed, protected


def _recover_markers(markers: dict[str, _RecoveryMarker], cutoff: float) -> int:
    removed = 0
    for marker in markers.values():
        if marker.modified_at > cutoff:
            continue
        _unlink_private_file(marker.path)
        removed += 1
    return removed


def _recover_inventory(
    connection: sqlite3.Connection,
    root: Path,
    raw_root: Path,
    cutoff: float,
    verify_referenced: bool,
) -> RawEvidenceRecovery:
    references = _referenced_raw_files(connection)
    markers, staged_files = _staging_inventory(raw_root)
    inventory = _raw_inventory(raw_root)
    _validate_references(root, references, inventory, verify_referenced)
    active_refs = {
        marker.blob_ref
        for marker in markers.values()
        if marker.modified_at > cutoff
    }
    orphan_removed, corrupt_removed, raw_protected = _recover_orphan_files(
        root, inventory, references, active_refs, cutoff
    )
    staging_removed, staging_protected = _recover_staging_files(
        staged_files, markers, cutoff
    )
    markers_removed = _recover_markers(markers, cutoff)
    return RawEvidenceRecovery(
        orphan_removed,
        corrupt_removed,
        staging_removed,
        markers_removed,
        raw_protected + staging_protected,
    )


def _database_root(connection: sqlite3.Connection) -> Path:
    database_rows = connection.execute("PRAGMA database_list").fetchall()
    database_file = next(
        (str(row["file"]) for row in database_rows if row["name"] == "main"), ""
    )
    if not database_file:
        raise SocialStoreError("social raw recovery requires a file-backed store")
    return Path(database_file).resolve(strict=True).parent.parent


def recover_raw_evidence(
    connection: sqlite3.Connection,
    *,
    now_epoch: float | None = None,
    grace_seconds: int = RAW_RECOVERY_GRACE_SECONDS,
    verify_referenced: bool = True,
) -> RawEvidenceRecovery:
    """Reclaim stale unreferenced blobs while preserving references and leases."""
    if grace_seconds < 0:
        raise SocialStoreError("social raw recovery grace must not be negative")
    if connection.in_transaction:
        raise SocialStoreError("social raw recovery requires autocommit state")
    root = _database_root(connection)
    raw_root = root / "sources" / "social" / "raw"
    if not raw_root.exists() and not raw_root.is_symlink():
        return RawEvidenceRecovery()
    _validated_directory(raw_root, "social raw evidence directory", repair=False)
    cutoff = (time.time() if now_epoch is None else now_epoch) - grace_seconds
    connection.execute("BEGIN IMMEDIATE")
    try:
        recovered = _recover_inventory(
            connection, root, raw_root, cutoff, verify_referenced
        )
        connection.execute("COMMIT")
        return recovered
    except Exception:
        if connection.in_transaction:
            connection.execute("ROLLBACK")
        raise
