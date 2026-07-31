#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Reject unsafe or over-budget members before WhatsApp ZIP extraction."""

from __future__ import annotations

import stat
import struct
import time
import zipfile
from pathlib import PurePosixPath

from knowledge_social_store import SocialStoreError

MAX_MEMBER_BYTES = 256 * 1024 * 1024
MAX_COMPRESSION_RATIO = 200
READ_CHUNK_BYTES = 1024 * 1024


def check_deadline(deadline: float) -> None:
    if time.monotonic() > deadline:
        raise SocialStoreError("WhatsApp export exceeded the elapsed-time budget")


def safe_zip_members(
    archive: zipfile.ZipFile, max_bytes: int, max_items: int, deadline: float
) -> list[zipfile.ZipInfo]:
    infos = archive.infolist()
    if len(infos) > max_items:
        raise SocialStoreError("WhatsApp export exceeds the member budget")
    seen: set[str] = set()
    total = 0
    safe: list[zipfile.ZipInfo] = []
    for info in infos:
        check_deadline(deadline)
        name = info.filename
        path = PurePosixPath(name)
        folded = name.casefold()
        mode = (info.external_attr >> 16) & 0o170000
        unsafe = not name or "\\" in name or "\x00" in name or path.is_absolute()
        unsafe = unsafe or any(part in {"", ".", ".."} for part in path.parts)
        if unsafe or folded in seen:
            raise SocialStoreError("WhatsApp export contains an unsafe or duplicate member path")
        seen.add(folded)
        if mode == stat.S_IFLNK or info.flag_bits & 0x1:
            raise SocialStoreError("WhatsApp export contains a link or encrypted member")
        if info.is_dir():
            continue
        if info.file_size > MAX_MEMBER_BYTES:
            raise SocialStoreError("WhatsApp export member exceeds the byte budget")
        if info.file_size > READ_CHUNK_BYTES and info.file_size > info.compress_size * MAX_COMPRESSION_RATIO:
            raise SocialStoreError("WhatsApp export member exceeds the compression-ratio budget")
        total += info.file_size
        if total > max_bytes:
            raise SocialStoreError("WhatsApp export exceeds the uncompressed byte budget")
        safe.append(info)
    return safe


def _directory_bounds(raw: bytes, max_items: int) -> tuple[int, int, int]:
    eocd_start = max(0, len(raw) - 65_557)
    eocd_offset = raw.rfind(b"PK\x05\x06", eocd_start)
    if eocd_offset < 0 or eocd_offset + 22 > len(raw):
        raise SocialStoreError("WhatsApp export has no valid ZIP directory")
    fields = struct.unpack_from("<4s4H2LH", raw, eocd_offset)
    _signature, disk, central_disk, disk_entries, entries, size, offset, comment = fields
    if eocd_offset + 22 + comment != len(raw):
        raise SocialStoreError("WhatsApp export has trailing or malformed ZIP data")
    if 0xFFFF in {disk_entries, entries} or 0xFFFFFFFF in {size, offset}:
        raise SocialStoreError("WhatsApp export cannot use ZIP64 metadata")
    if disk != 0 or central_disk != 0 or disk_entries != entries:
        raise SocialStoreError("WhatsApp export cannot span multiple ZIP disks")
    if entries > max_items or offset + size > eocd_offset:
        raise SocialStoreError("WhatsApp export ZIP directory exceeds its budget")
    return entries, offset, size


def _count_directory_entries(raw: bytes, offset: int, size: int, max_items: int) -> int:
    cursor = offset
    central_end = offset + size
    counted = 0
    while cursor < central_end:
        if cursor + 46 > central_end or raw[cursor : cursor + 4] != b"PK\x01\x02":
            raise SocialStoreError("WhatsApp export ZIP directory is malformed")
        name_length, extra_length, comment_length = struct.unpack_from("<HHH", raw, cursor + 28)
        cursor += 46 + name_length + extra_length + comment_length
        counted += 1
        if cursor > central_end or counted > max_items:
            raise SocialStoreError("WhatsApp export ZIP directory exceeds its budget")
    if cursor != central_end:
        raise SocialStoreError("WhatsApp export ZIP directory count is inconsistent")
    return counted


def preflight_zip(raw: bytes, max_items: int) -> None:
    entries, offset, size = _directory_bounds(raw, max_items)
    if _count_directory_entries(raw, offset, size, max_items) != entries:
        raise SocialStoreError("WhatsApp export ZIP directory count is inconsistent")
