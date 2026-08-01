#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validated inventories of raw evidence, staging leases, and references."""

from __future__ import annotations

import json
import os
import re
import sqlite3
from dataclasses import dataclass
from pathlib import Path

from _knowledge_social_store_raw import _validated_raw_ref
from _knowledge_social_store_raw_fs import (
    _validated_directory,
    _validated_private_file,
)
from _knowledge_social_store_support import (
    OPAQUE_ID,
    SHA256_HEX,
    SocialStoreError,
)

_STAGE_TOKEN = re.compile(r"^[0-9a-f]{32}$")
_MARKER_FIELDS = frozenset({"version", "token", "digest", "blob_ref"})


@dataclass(frozen=True)
class _RecoveryMarker:
    path: Path
    blob_ref: str
    modified_at: float


def _read_marker_payload(path: Path) -> tuple[dict[str, object], float]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        before = path.lstat()
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "r", encoding="utf-8") as source:
            descriptor = -1
            opened = os.fstat(source.fileno())
            if (before.st_dev, before.st_ino) != (opened.st_dev, opened.st_ino):
                raise SocialStoreError("social raw staging marker changed while opening")
            marker = json.load(source)
    except SocialStoreError:
        raise
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        raise SocialStoreError("social raw staging marker is invalid") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    if not isinstance(marker, dict):
        raise SocialStoreError("social raw staging marker is invalid")
    return marker, before.st_mtime


def _read_marker(path: Path) -> _RecoveryMarker:
    _validated_private_file(path, "social raw staging marker")
    token = path.stem
    if _STAGE_TOKEN.fullmatch(token) is None:
        raise SocialStoreError("social raw staging marker name is invalid")
    marker, modified_at = _read_marker_payload(path)
    if set(marker) != _MARKER_FIELDS:
        raise SocialStoreError("social raw staging marker is invalid")
    if marker.get("version") != 1 or marker.get("token") != token:
        raise SocialStoreError("social raw staging marker is invalid")
    digest = marker.get("digest")
    blob_ref = marker.get("blob_ref")
    if not isinstance(digest, str) or SHA256_HEX.fullmatch(digest) is None:
        raise SocialStoreError("social raw staging marker is invalid")
    if not isinstance(blob_ref, str):
        raise SocialStoreError("social raw staging marker is invalid")
    _, _, _, filename = _validated_raw_ref(blob_ref)
    if filename != f"{digest}.json.gz":
        raise SocialStoreError("social raw staging marker is invalid")
    return _RecoveryMarker(path, blob_ref, modified_at)


def _staging_inventory(
    raw_root: Path,
) -> tuple[dict[str, _RecoveryMarker], dict[str, Path]]:
    staging_directory = raw_root / ".staging"
    if not staging_directory.exists() and not staging_directory.is_symlink():
        return {}, {}
    _validated_directory(staging_directory, "social raw staging directory", repair=False)
    markers: dict[str, _RecoveryMarker] = {}
    staged_files: dict[str, Path] = {}
    for path in staging_directory.iterdir():
        if path.is_symlink():
            raise SocialStoreError("social raw staging symlink is not allowed")
        if path.suffix == ".json":
            markers[path.stem] = _read_marker(path)
        elif path.suffix == ".stage" and _STAGE_TOKEN.fullmatch(path.stem):
            _validated_private_file(path, "social raw staging file")
            staged_files[path.stem] = path
        else:
            raise SocialStoreError("social raw staging inventory is invalid")
    return markers, staged_files


def _validated_inventory_directory(path: Path, label: str) -> Path:
    if path.is_symlink() or OPAQUE_ID.fullmatch(path.name) is None:
        raise SocialStoreError(f"{label} is unsafe")
    return _validated_directory(path, label, repair=False)


def _provider_directories(raw_root: Path) -> list[Path]:
    providers: list[Path] = []
    for path in raw_root.iterdir():
        if path.name == ".staging":
            continue
        providers.append(
            _validated_inventory_directory(path, "social raw provider directory")
        )
    return providers


def _connection_directories(provider_path: Path) -> list[Path]:
    return [
        _validated_inventory_directory(path, "social raw connection directory")
        for path in provider_path.iterdir()
    ]


def _connection_raw_files(connection_path: Path) -> list[Path]:
    files: list[Path] = []
    for path in connection_path.iterdir():
        if path.is_symlink() or re.fullmatch(
            r"[0-9a-f]{64}\.json\.gz", path.name
        ) is None:
            raise SocialStoreError("social raw evidence inventory is unsafe")
        _validated_private_file(path, "social raw evidence")
        files.append(path)
    return files


def _raw_inventory(raw_root: Path) -> dict[str, Path]:
    inventory: dict[str, Path] = {}
    root = raw_root.parents[2]
    for provider_path in _provider_directories(raw_root):
        for connection_path in _connection_directories(provider_path):
            for path in _connection_raw_files(connection_path):
                inventory[path.relative_to(root).as_posix()] = path
    return inventory


def _referenced_raw_files(connection: sqlite3.Connection) -> set[str]:
    references: set[str] = set()
    rows = connection.execute(
        "SELECT provider,connection_id,blob_ref FROM fetch_batches"
    ).fetchall()
    for row in rows:
        blob_ref = str(row["blob_ref"])
        _, provider, connection_id, _ = _validated_raw_ref(blob_ref)
        if provider != row["provider"] or connection_id != row["connection_id"]:
            raise SocialStoreError("fetch batch raw evidence scope does not match")
        references.add(blob_ref)
    return references


def _is_old(path: Path, cutoff: float) -> bool:
    try:
        return path.lstat().st_mtime <= cutoff
    except OSError as error:
        raise SocialStoreError("social raw evidence could not be inspected") from error
