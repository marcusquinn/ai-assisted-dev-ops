#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded filesystem and ZIP handling for native Medium exports."""

from __future__ import annotations

import io
import os
import stat
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from _knowledge_social_medium_html import HtmlNode, parse_html
from knowledge_social_store import SocialStoreError

MAX_MEMBER_BYTES = 32 * 1024 * 1024


@dataclass(frozen=True)
class MediumArchiveContents:
    members: list[zipfile.ZipInfo]
    documents: dict[str, tuple[bytes, HtmlNode]]


def _unsafe_member_path(name: str, path: PurePosixPath) -> bool:
    markers = (
        not name,
        "\\" in name,
        "\x00" in name,
        path.is_absolute(),
        any(part in {"", ".", ".."} for part in path.parts),
    )
    return any(markers)


def _validate_member_path(
    info: zipfile.ZipInfo, seen: set[str], folded: set[str]
) -> None:
    name = info.filename
    if _unsafe_member_path(name, PurePosixPath(name)):
        raise SocialStoreError("Medium archive contains an unsafe member path")
    if name in seen:
        raise SocialStoreError("Medium archive contains duplicate member paths")
    folded_name = name.casefold()
    if folded_name in folded:
        raise SocialStoreError("Medium archive contains duplicate member paths")
    seen.add(name)
    folded.add(folded_name)


def _validate_member_metadata(info: zipfile.ZipInfo) -> None:
    mode = (info.external_attr >> 16) & 0o170000
    if mode == stat.S_IFLNK:
        raise SocialStoreError("Medium archive cannot contain symbolic links")
    if info.flag_bits & 0x1:
        raise SocialStoreError("Medium archive cannot contain encrypted members")
    if info.file_size > MAX_MEMBER_BYTES:
        raise SocialStoreError("Medium archive member exceeds the byte budget")


def _safe_members(
    archive: zipfile.ZipFile, max_bytes: int, max_items: int
) -> list[zipfile.ZipInfo]:
    infos = archive.infolist()
    if len(infos) > max_items:
        raise SocialStoreError("Medium archive exceeds the member budget")
    seen: set[str] = set()
    folded: set[str] = set()
    total = 0
    safe: list[zipfile.ZipInfo] = []
    for info in infos:
        _validate_member_path(info, seen, folded)
        _validate_member_metadata(info)
        if info.is_dir():
            continue
        total += info.file_size
        if total > max_bytes:
            raise SocialStoreError("Medium archive exceeds the uncompressed byte budget")
        safe.append(info)
    return sorted(safe, key=lambda member: member.filename)


def read_regular_archive(path: Path, max_bytes: int) -> bytes:
    """Open once without following symlinks and reject in-place changes."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if nofollow:
        flags |= nofollow
    elif path.is_symlink():
        raise SocialStoreError("Medium archive must be a regular non-symlink file")
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as source:
            descriptor = -1
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise SocialStoreError(
                    "Medium archive must be a regular non-symlink file"
                )
            if before.st_size <= 0 or before.st_size > max_bytes:
                raise SocialStoreError(
                    "Medium archive exceeds the compressed byte budget"
                )
            payload = source.read(max_bytes + 1)
            after = os.fstat(source.fileno())
    except SocialStoreError:
        raise
    except OSError as error:
        raise SocialStoreError("Medium archive could not be opened safely") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    )
    changed = len(payload) > max_bytes
    changed = changed or len(payload) != before.st_size
    changed = changed or before_identity != after_identity
    if changed:
        raise SocialStoreError("Medium archive changed while it was being read")
    return payload


def read_archive_contents(
    payload: bytes, max_bytes: int, max_items: int
) -> MediumArchiveContents:
    """Validate ZIP metadata and parse each bounded HTML member."""
    try:
        with zipfile.ZipFile(io.BytesIO(payload), "r") as archive:
            members = _safe_members(archive, max_bytes, max_items)
            documents: dict[str, tuple[bytes, HtmlNode]] = {}
            for info in members:
                if not info.filename.lower().endswith(".html"):
                    continue
                member_payload = archive.read(info)
                documents[info.filename] = (member_payload, parse_html(member_payload))
    except (
        RecursionError,
        RuntimeError,
        zipfile.BadZipFile,
        zipfile.LargeZipFile,
    ) as error:
        raise SocialStoreError("Medium archive is not a supported ZIP file") from error
    return MediumArchiveContents(members, documents)
