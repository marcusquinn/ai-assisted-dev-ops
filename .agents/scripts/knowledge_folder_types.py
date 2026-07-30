#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded file classification primitives for folder knowledge ingestion."""

from __future__ import annotations

import fnmatch
import hashlib
import json
import mimetypes
import os
import re
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any


TEXT_EXTENSIONS = {
    ".csv", ".htm", ".html", ".json", ".jsonl", ".log", ".md", ".rst",
    ".tex", ".tsv", ".txt", ".xml", ".yaml", ".yml",
}
DOCUMENT_EXTENSIONS = {
    ".docx", ".odp", ".ods", ".odt", ".pdf", ".pptx", ".rtf", ".xlsx",
}
IMAGE_EXTENSIONS = {".bmp", ".gif", ".heic", ".jpeg", ".jpg", ".png", ".tif", ".tiff", ".webp"}
AUDIO_EXTENSIONS = {".aac", ".flac", ".m4a", ".mp3", ".oga", ".ogg", ".wav"}
VIDEO_EXTENSIONS = {".avi", ".m4v", ".mkv", ".mov", ".mp4", ".webm"}
EMAIL_EXTENSIONS = {".eml", ".emlx"}
MAILBOX_EXTENSIONS = {".mbox"}
ARCHIVE_DOCUMENT_EXTENSIONS = {".docx", ".odp", ".ods", ".odt", ".pptx", ".xlsx"}
DEFAULT_EXCLUDES = (".git", ".git/**", "_knowledge", "_knowledge/**")
_CREDENTIAL_WORD = re.compile(
    r"(?i)(access[_-]?token|api[_-]?key|authorization|client[_-]?secret|password|private[_-]?key|refresh[_-]?token|session[_-]?token)"
)


@dataclass(frozen=True)
class FileClassification:
    """Validated local classification without reading beyond a bounded prefix."""

    kind: str
    mime_type: str
    processors: tuple[str, ...]
    supported: bool
    valid: bool
    reason: str | None = None


def sha256_file(path: Path, chunk_size: int = 1024 * 1024) -> str:
    """Hash a regular file without loading it into memory."""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(chunk_size):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_fd(descriptor: int, chunk_size: int = 1024 * 1024) -> str:
    """Hash the already-open file that will be copied into canonical storage."""
    digest = hashlib.sha256()
    duplicate = os.dup(descriptor)
    try:
        os.lseek(duplicate, 0, os.SEEK_SET)
        with os.fdopen(duplicate, "rb", closefd=True) as handle:
            duplicate = -1
            while chunk := handle.read(chunk_size):
                digest.update(chunk)
    finally:
        if duplicate >= 0:
            os.close(duplicate)
    return digest.hexdigest()


def sha256_bytes(data: bytes) -> str:
    """Hash generated child evidence."""
    return hashlib.sha256(data).hexdigest()


def source_id_for_digest(kind: str, digest: str) -> str:
    """Return a deterministic source ID independent of private filenames."""
    prefix = "attachment" if kind == "attachment" else "folder"
    return f"{prefix}-{digest[:24]}"


def atomic_write_json(path: Path, value: dict[str, Any]) -> None:
    """Replace a private JSON projection atomically with restrictive permissions."""
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8", closefd=True) as handle:
            descriptor = -1
            json.dump(value, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        temporary.replace(path)
        fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def fsync_directory(path: Path) -> None:
    """Durably publish a rename on filesystems that support directory fsync."""
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    descriptor = os.open(path, flags)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def excluded(relative_path: str, patterns: list[str]) -> bool:
    """Match an inventory-relative path against explicit bounded exclusions."""
    return any(fnmatch.fnmatchcase(relative_path, pattern) for pattern in (*DEFAULT_EXCLUDES, *patterns))


def sanitize_reason(reason: object) -> str:
    """Produce a short diagnostic that cannot disclose host paths or credentials."""
    text = str(reason).replace("\r", " ").replace("\n", " ")
    text = re.sub(r"(?:file://)?/(?:[^\s/:]+/)+[^\s:]*", "<path>", text)
    text = _CREDENTIAL_WORD.sub("credential", text)
    return text[:160] or "unspecified error"


def _valid_signature(extension: str, prefix: bytes) -> bool:
    if extension == ".pdf":
        return prefix.startswith(b"%PDF-")
    if extension in ARCHIVE_DOCUMENT_EXTENSIONS:
        return prefix.startswith(b"PK\x03\x04")
    if extension in {".png"}:
        return prefix.startswith(b"\x89PNG\r\n\x1a\n")
    if extension in {".jpg", ".jpeg"}:
        return prefix.startswith(b"\xff\xd8\xff")
    if extension == ".gif":
        return prefix.startswith((b"GIF87a", b"GIF89a"))
    if extension == ".webp":
        return prefix.startswith(b"RIFF") and prefix[8:12] == b"WEBP"
    if extension in {".tif", ".tiff"}:
        return prefix.startswith((b"II*\x00", b"MM\x00*"))
    if extension == ".bmp":
        return prefix.startswith(b"BM")
    if extension == ".wav":
        return prefix.startswith(b"RIFF") and prefix[8:12] == b"WAVE"
    if extension == ".flac":
        return prefix.startswith(b"fLaC")
    if extension in {".ogg", ".oga"}:
        return prefix.startswith(b"OggS")
    if extension == ".mp3":
        return prefix.startswith(b"ID3") or (len(prefix) > 1 and prefix[0] == 0xFF and prefix[1] & 0xE0 == 0xE0)
    if extension in {".m4a", ".m4v", ".mov", ".mp4"}:
        return len(prefix) >= 12 and prefix[4:8] == b"ftyp"
    if extension == ".avi":
        return prefix.startswith(b"RIFF") and prefix[8:12] == b"AVI "
    if extension in {".mkv", ".webm"}:
        return prefix.startswith(b"\x1aE\xdf\xa3")
    if extension == ".eml":
        return b":" in prefix.partition(b"\n")[0] or b"\nFrom:" in prefix or b"\nSubject:" in prefix
    if extension == ".emlx":
        first_line, separator, remainder = prefix.partition(b"\n")
        return bool(separator and first_line.isdigit() and b":" in remainder)
    if extension == ".mbox":
        return prefix.startswith(b"From ")
    return True


def classify_bytes(name: str, prefix: bytes) -> FileClassification:
    """Classify a named payload from a bounded byte prefix."""
    extension = Path(name).suffix.lower()
    guessed_mime = mimetypes.guess_type(name, strict=False)[0] or "application/octet-stream"
    if extension in TEXT_EXTENSIONS:
        try:
            prefix.decode("utf-8")
        except UnicodeDecodeError:
            return FileClassification("document", guessed_mime, ("text-extraction",), True, False, "text is not valid UTF-8")
        return FileClassification("document", guessed_mime, ("text-extraction",), True, True)
    if extension in DOCUMENT_EXTENSIONS:
        valid = _valid_signature(extension, prefix)
        return FileClassification("document", guessed_mime, ("text-extraction",), True, valid, None if valid else "document signature does not match extension")
    if extension in IMAGE_EXTENSIONS:
        valid = _valid_signature(extension, prefix)
        return FileClassification("image", guessed_mime, ("metadata", "ocr"), True, valid, None if valid else "image signature does not match extension")
    if extension in AUDIO_EXTENSIONS:
        valid = _valid_signature(extension, prefix)
        return FileClassification("audio", guessed_mime, ("metadata", "transcription"), True, valid, None if valid else "audio signature does not match extension")
    if extension in VIDEO_EXTENSIONS:
        valid = _valid_signature(extension, prefix)
        return FileClassification("video", guessed_mime, ("metadata", "transcription", "keyframes"), True, valid, None if valid else "video signature does not match extension")
    if extension in EMAIL_EXTENSIONS:
        valid = _valid_signature(extension, prefix)
        return FileClassification("email", "message/rfc822", ("email-parse",), True, valid, None if valid else "email structure is malformed")
    if extension in MAILBOX_EXTENSIONS:
        valid = _valid_signature(extension, prefix)
        return FileClassification("export", "application/mbox", ("mailbox-expand",), True, valid, None if valid else "mailbox structure is malformed")
    return FileClassification("unknown", guessed_mime, (), False, True, "unsupported format")


def classify_fd(name: str, descriptor: int) -> FileClassification:
    """Classify one already-open file without another path resolution."""
    try:
        prefix = os.pread(descriptor, 8192, 0)
    except OSError as error:
        guessed_mime = mimetypes.guess_type(name, strict=False)[0] or "application/octet-stream"
        return FileClassification("unknown", guessed_mime, (), False, False, sanitize_reason(error))
    return classify_bytes(name, prefix)
