#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded regular-file and ZIP handling for Slack JSON exports."""

from __future__ import annotations

import io
import json
import os
import stat
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from knowledge_social_store import SocialStoreError

MAX_MEMBER_BYTES = 16 * 1024 * 1024


def _unsafe_member_path(name: str, path: PurePosixPath) -> bool:
    return any(
        (
            not name,
            "\\" in name,
            "\x00" in name,
            path.is_absolute(),
            any(part in {"", ".", ".."} for part in path.parts),
        )
    )


def _validate_member_path(
    info: zipfile.ZipInfo, seen: set[str], folded: set[str]
) -> None:
    name = info.filename
    if _unsafe_member_path(name, PurePosixPath(name)):
        raise SocialStoreError("Slack export contains an unsafe member path")
    if name in seen or name.casefold() in folded:
        raise SocialStoreError("Slack export contains duplicate member paths")
    seen.add(name)
    folded.add(name.casefold())


def _validate_member_metadata(info: zipfile.ZipInfo) -> None:
    mode = (info.external_attr >> 16) & 0o170000
    if mode == stat.S_IFLNK:
        raise SocialStoreError("Slack export cannot contain symbolic links")
    if info.flag_bits & 0x1:
        raise SocialStoreError("Slack export cannot contain encrypted members")
    if info.file_size > MAX_MEMBER_BYTES:
        raise SocialStoreError("Slack export member exceeds the byte budget")


def _archive_open_flags(path: Path) -> int:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if nofollow:
        flags |= nofollow
    elif path.is_symlink():
        raise SocialStoreError("Slack export must be a regular non-symlink file")
    return flags


def _validate_archive_metadata(metadata: os.stat_result, max_bytes: int) -> None:
    if not stat.S_ISREG(metadata.st_mode):
        raise SocialStoreError("Slack export must be a regular non-symlink file")
    if metadata.st_size <= 0 or metadata.st_size > max_bytes:
        raise SocialStoreError("Slack export exceeds the compressed byte budget")


def _read_archive_descriptor(
    path: Path, max_bytes: int
) -> tuple[bytes, os.stat_result, os.stat_result]:
    descriptor = os.open(path, _archive_open_flags(path))
    try:
        before = os.fstat(descriptor)
        _validate_archive_metadata(before, max_bytes)
        with os.fdopen(os.dup(descriptor), "rb") as source:
            payload = source.read(max_bytes + 1)
        after = os.fstat(descriptor)
    finally:
        os.close(descriptor)
    return payload, before, after


def _file_identity(metadata: os.stat_result) -> tuple[int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_size,
        metadata.st_mtime_ns,
    )


def read_regular_archive(path: Path, max_bytes: int) -> bytes:
    """Open one archive without following symlinks and reject in-place changes."""
    try:
        payload, before, after = _read_archive_descriptor(path, max_bytes)
    except SocialStoreError:
        raise
    except OSError as error:
        raise SocialStoreError("Slack export could not be opened safely") from error
    if len(payload) > max_bytes:
        raise SocialStoreError("Slack export changed while it was being read")
    observed = (len(payload), _file_identity(after))
    expected = (before.st_size, _file_identity(before))
    if observed != expected:
        raise SocialStoreError("Slack export changed while it was being read")
    return payload


@dataclass(frozen=True)
class SlackArchiveIndex:
    """Validated ZIP metadata with bounded exact-member readers."""

    archive: zipfile.ZipFile
    members: dict[str, zipfile.ZipInfo]

    def __enter__(self) -> SlackArchiveIndex:
        return self

    def __exit__(self, *_error: object) -> None:
        self.archive.close()

    def member_bytes(self, name: str) -> bytes:
        info = self.members.get(name)
        if info is None:
            raise SocialStoreError("Slack export is missing a required JSON member")
        try:
            value = self.archive.read(info)
        except (
            NotImplementedError,
            OSError,
            RuntimeError,
            zipfile.BadZipFile,
            zipfile.LargeZipFile,
        ) as error:
            raise SocialStoreError("Slack export member could not be read") from error
        if len(value) != info.file_size or len(value) > MAX_MEMBER_BYTES:
            raise SocialStoreError("Slack export member changed or exceeded its budget")
        return value

    def json_value(self, name: str) -> Any:
        payload = self.member_bytes(name)
        try:
            return json.loads(payload.decode("utf-8"))
        except (RecursionError, UnicodeDecodeError, json.JSONDecodeError) as error:
            raise SocialStoreError("Slack export member is not valid UTF-8 JSON") from error


def index_archive(
    payload: bytes, max_uncompressed_bytes: int, max_items: int
) -> SlackArchiveIndex:
    """Validate all ZIP metadata before any selected member is interpreted."""
    try:
        with zipfile.ZipFile(io.BytesIO(payload), "r") as archive:
            infos = archive.infolist()
    except (RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise SocialStoreError("Slack export is not a supported ZIP file") from error
    if len(infos) > max_items:
        raise SocialStoreError("Slack export exceeds the member budget")
    seen: set[str] = set()
    folded: set[str] = set()
    total = 0
    members: dict[str, zipfile.ZipInfo] = {}
    for info in infos:
        _validate_member_path(info, seen, folded)
        _validate_member_metadata(info)
        if info.is_dir():
            continue
        total += info.file_size
        if total > max_uncompressed_bytes:
            raise SocialStoreError("Slack export exceeds the uncompressed byte budget")
        members[info.filename] = info
    try:
        archive = zipfile.ZipFile(io.BytesIO(payload), "r")
    except (RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise SocialStoreError("Slack export is not a supported ZIP file") from error
    return SlackArchiveIndex(archive, members)
