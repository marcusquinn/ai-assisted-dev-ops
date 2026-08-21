#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded readers for local auction inventory archives."""

from __future__ import annotations

import gzip
import io
import os
import stat
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

MAX_COMPRESSED_BYTES = 32 * 1024 * 1024
MAX_UNCOMPRESSED_BYTES = 64 * 1024 * 1024
MAX_COMPRESSION_RATIO = 100
NESTED_ARCHIVE_SUFFIXES = frozenset({".zip", ".gz", ".tgz", ".bz2", ".xz"})


class DomainOpportunityFileError(ValueError):
    """Raised when a local inventory file is unsafe or incompatible."""


def _read_limited(handle: Any, limit: int = MAX_UNCOMPRESSED_BYTES) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = handle.read(1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > limit:
            raise DomainOpportunityFileError("archive content exceeds uncompressed size limit")
        chunks.append(chunk)


def _regular_input(path: Path) -> None:
    if path.is_symlink() or not path.is_file():
        raise DomainOpportunityFileError("input must be a regular local file")
    if path.stat().st_size > MAX_COMPRESSED_BYTES:
        raise DomainOpportunityFileError("input exceeds compressed size limit")


def _check_ratio(compressed: int, uncompressed: int, message: str) -> None:
    if uncompressed > compressed * MAX_COMPRESSION_RATIO:
        raise DomainOpportunityFileError(message)


def _read_gzip(raw: bytes) -> tuple[bytes, str]:
    with gzip.GzipFile(fileobj=io.BytesIO(raw)) as handle:
        content = _read_limited(handle)
    _check_ratio(len(raw), len(content), "gzip compression ratio exceeds limit")
    return content, "gzip"


def _zip_entry_is_safe(entry: zipfile.ZipInfo) -> bool:
    member = PurePosixPath(entry.filename)
    unsafe_markers = (
        member.is_absolute(),
        ".." in member.parts,
        entry.is_dir(),
        bool(entry.flag_bits & 0x1),
        stat.S_ISLNK(entry.external_attr >> 16),
        member.suffix.casefold() in NESTED_ARCHIVE_SUFFIXES,
    )
    return not any(unsafe_markers)


def _only_zip_entry(archive: zipfile.ZipFile) -> zipfile.ZipInfo:
    entries = archive.infolist()
    if not entries:
        raise DomainOpportunityFileError("ZIP archive contains no files")
    if not all(_zip_entry_is_safe(entry) for entry in entries):
        raise DomainOpportunityFileError("ZIP archive contains unsafe, encrypted, linked, or nested content")
    if len(entries) != 1:
        raise DomainOpportunityFileError("ZIP archive must contain exactly one inventory file")
    return entries[0]


def _read_zip(raw: bytes) -> tuple[bytes, str]:
    with zipfile.ZipFile(io.BytesIO(raw)) as archive:
        entry = _only_zip_entry(archive)
        if entry.file_size > MAX_UNCOMPRESSED_BYTES:
            raise DomainOpportunityFileError("archive content exceeds uncompressed size limit")
        if entry.compress_size:
            _check_ratio(entry.compress_size, entry.file_size, "ZIP compression ratio exceeds limit")
        with archive.open(entry) as handle:
            return _read_limited(handle), "zip"


def _read_plain(raw: bytes) -> tuple[bytes, str]:
    if len(raw) > MAX_UNCOMPRESSED_BYTES:
        raise DomainOpportunityFileError("input exceeds uncompressed size limit")
    return raw, "plain"


def read_inventory(path: str | os.PathLike[str]) -> tuple[bytes, str]:
    """Read one bounded plain, gzip, or safe single-file ZIP inventory."""
    source = Path(path).expanduser()
    _regular_input(source)
    raw = source.read_bytes()
    readers = ((b"\x1f\x8b", _read_gzip), (b"PK\x03\x04", _read_zip))
    reader = next((candidate for magic, candidate in readers if raw.startswith(magic)), _read_plain)
    return reader(raw)
