#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded file and ZIP handling for user-authorized WhatsApp exports."""

from __future__ import annotations

import hashlib
import io
import os
import stat
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from _knowledge_social_whatsapp_zip_guard import (
    MAX_MEMBER_BYTES,
    READ_CHUNK_BYTES,
    check_deadline as _check_deadline,
    preflight_zip as _preflight_zip,
    safe_zip_members as _safe_zip_members,
)
from knowledge_social_store import SocialStoreError

MAX_TRANSCRIPT_BYTES = 32 * 1024 * 1024


@dataclass(frozen=True)
class ExportContents:
    transcript: bytes
    media: dict[str, tuple[str, str, int]]
    raw: bytes
    raw_sha256: str


def _read_regular_digest(
    path: Path, max_bytes: int, deadline: float | None = None
) -> tuple[bytes, str]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        if not getattr(os, "O_NOFOLLOW", 0) and path.is_symlink():
            raise SocialStoreError("WhatsApp export must be a regular non-symlink file")
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as source:
            descriptor = -1
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode) or not 0 < before.st_size <= max_bytes:
                raise SocialStoreError("WhatsApp export exceeds the byte budget")
            digest = hashlib.sha256()
            chunks: list[bytes] = []
            total = 0
            while chunk := source.read(READ_CHUNK_BYTES):
                if deadline is not None:
                    _check_deadline(deadline)
                total += len(chunk)
                if total > max_bytes:
                    raise SocialStoreError("WhatsApp export exceeds the byte budget")
                digest.update(chunk)
                chunks.append(chunk)
            payload = b"".join(chunks)
            after = os.fstat(source.fileno())
    except SocialStoreError:
        raise
    except OSError as error:
        raise SocialStoreError("WhatsApp export could not be opened safely") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    before_identity = (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns)
    after_identity = (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns)
    if len(payload) != before.st_size or before_identity != after_identity:
        raise SocialStoreError("WhatsApp export changed while it was being read")
    return payload, digest.hexdigest()


def _read_regular(path: Path, max_bytes: int) -> bytes:
    payload, _digest = _read_regular_digest(path, max_bytes)
    return payload


def _read_zip_member(
    archive: zipfile.ZipFile,
    info: zipfile.ZipInfo,
    deadline: float,
    *,
    capture: bool,
) -> tuple[bytes | None, str, int]:
    digest = hashlib.sha256()
    chunks: list[bytes] = []
    total = 0
    with archive.open(info, "r") as source:
        while chunk := source.read(READ_CHUNK_BYTES):
            _check_deadline(deadline)
            total += len(chunk)
            if total > info.file_size or total > MAX_MEMBER_BYTES:
                raise SocialStoreError("WhatsApp export member exceeded its declared size")
            digest.update(chunk)
            if capture:
                chunks.append(chunk)
    if total != info.file_size:
        raise SocialStoreError("WhatsApp export member size does not match its metadata")
    return (b"".join(chunks) if capture else None), digest.hexdigest(), total


def _read_contents(
    path: Path, max_bytes: int, max_items: int, deadline: float
) -> ExportContents:
    raw, raw_sha256 = _read_regular_digest(path, max_bytes, deadline)
    if path.suffix.casefold() == ".txt":
        if len(raw) > MAX_TRANSCRIPT_BYTES:
            raise SocialStoreError("WhatsApp transcript exceeds the byte budget")
        return ExportContents(raw, {}, raw, raw_sha256)
    try:
        _preflight_zip(raw, max_items)
        with zipfile.ZipFile(io.BytesIO(raw), "r") as archive:
            members = _safe_zip_members(archive, max_bytes, max_items, deadline)
            transcripts = [info for info in members if info.filename.casefold().endswith(".txt")]
            if len(transcripts) != 1:
                raise SocialStoreError("WhatsApp ZIP export requires exactly one transcript")
            transcript_info = transcripts[0]
            if transcript_info.file_size > MAX_TRANSCRIPT_BYTES:
                raise SocialStoreError("WhatsApp transcript exceeds the byte budget")
            transcript, _digest, _size = _read_zip_member(archive, transcript_info, deadline, capture=True)
            if transcript is None:
                raise SocialStoreError("WhatsApp transcript could not be retained")
            media: dict[str, tuple[str, str, int]] = {}
            for info in members:
                _check_deadline(deadline)
                if info == transcript_info:
                    continue
                basename = PurePosixPath(info.filename).name
                key = basename.casefold()
                if key in media:
                    raise SocialStoreError("WhatsApp media basenames must be unique")
                _unused, media_digest, media_size = _read_zip_member(archive, info, deadline, capture=False)
                media[key] = (info.filename, media_digest, media_size)
            return ExportContents(transcript, media, raw, raw_sha256)
    except SocialStoreError:
        raise
    except (RuntimeError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
        raise SocialStoreError("WhatsApp export is not a supported ZIP file") from error
