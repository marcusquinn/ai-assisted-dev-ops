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
from typing import Any, Callable


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


@dataclass(frozen=True)
class ClassificationRule:
    """Classification data shared by extension groups."""

    kind: str
    processors: tuple[str, ...]
    invalid_reason: str
    mime_override: str | None = None
    requires_utf8: bool = False


SignatureValidator = Callable[[bytes], bool]


def _prefix_validator(*markers: bytes) -> SignatureValidator:
    return lambda prefix: prefix.startswith(markers)


def _riff_validator(marker: bytes) -> SignatureValidator:
    return lambda prefix: prefix.startswith(b"RIFF") and prefix[8:12] == marker


def _iso_media(prefix: bytes) -> bool:
    return len(prefix) >= 12 and prefix[4:8] == b"ftyp"


def _mp3(prefix: bytes) -> bool:
    if prefix.startswith(b"ID3"):
        return True
    return len(prefix) > 1 and prefix[0] == 0xFF and prefix[1] & 0xE0 == 0xE0


def _eml(prefix: bytes) -> bool:
    first_line = prefix.partition(b"\n")[0]
    return any(marker in prefix for marker in (b"\nFrom:", b"\nSubject:")) or b":" in first_line


def _emlx(prefix: bytes) -> bool:
    first_line, separator, remainder = prefix.partition(b"\n")
    return bool(separator and first_line.isdigit() and b":" in remainder)


_SIGNATURE_VALIDATORS: dict[str, SignatureValidator] = {
    ".pdf": _prefix_validator(b"%PDF-"),
    **{extension: _prefix_validator(b"PK\x03\x04") for extension in ARCHIVE_DOCUMENT_EXTENSIONS},
    ".png": _prefix_validator(b"\x89PNG\r\n\x1a\n"),
    ".jpg": _prefix_validator(b"\xff\xd8\xff"),
    ".jpeg": _prefix_validator(b"\xff\xd8\xff"),
    ".gif": _prefix_validator(b"GIF87a", b"GIF89a"),
    ".webp": _riff_validator(b"WEBP"),
    ".tif": _prefix_validator(b"II*\x00", b"MM\x00*"),
    ".tiff": _prefix_validator(b"II*\x00", b"MM\x00*"),
    ".bmp": _prefix_validator(b"BM"),
    ".wav": _riff_validator(b"WAVE"),
    ".flac": _prefix_validator(b"fLaC"),
    ".ogg": _prefix_validator(b"OggS"),
    ".oga": _prefix_validator(b"OggS"),
    ".mp3": _mp3,
    ".m4a": _iso_media,
    ".m4v": _iso_media,
    ".mov": _iso_media,
    ".mp4": _iso_media,
    ".avi": _riff_validator(b"AVI "),
    ".mkv": _prefix_validator(b"\x1aE\xdf\xa3"),
    ".webm": _prefix_validator(b"\x1aE\xdf\xa3"),
    ".eml": _eml,
    ".emlx": _emlx,
    ".mbox": _prefix_validator(b"From "),
}


_RULE_GROUPS = (
    (TEXT_EXTENSIONS, ClassificationRule("document", ("text-extraction",), "text is not valid UTF-8", requires_utf8=True)),
    (DOCUMENT_EXTENSIONS, ClassificationRule("document", ("text-extraction",), "document signature does not match extension")),
    (IMAGE_EXTENSIONS, ClassificationRule("image", ("metadata", "ocr"), "image signature does not match extension")),
    (AUDIO_EXTENSIONS, ClassificationRule("audio", ("metadata", "transcription"), "audio signature does not match extension")),
    (VIDEO_EXTENSIONS, ClassificationRule("video", ("metadata", "transcription", "keyframes"), "video signature does not match extension")),
    (EMAIL_EXTENSIONS, ClassificationRule("email", ("email-parse",), "email structure is malformed", "message/rfc822")),
    (MAILBOX_EXTENSIONS, ClassificationRule("export", ("mailbox-expand",), "mailbox structure is malformed", "application/mbox")),
)
_CLASSIFICATION_RULES = {
    extension: rule
    for extensions, rule in _RULE_GROUPS
    for extension in extensions
}


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
    validator = _SIGNATURE_VALIDATORS.get(extension)
    return validator(prefix) if validator is not None else True


def _valid_utf8(prefix: bytes) -> bool:
    try:
        prefix.decode("utf-8")
    except UnicodeDecodeError:
        return False
    return True


def classify_bytes(name: str, prefix: bytes) -> FileClassification:
    """Classify a named payload from a bounded byte prefix."""
    extension = Path(name).suffix.lower()
    guessed_mime = mimetypes.guess_type(name, strict=False)[0] or "application/octet-stream"
    rule = _CLASSIFICATION_RULES.get(extension)
    if rule is None:
        return FileClassification("unknown", guessed_mime, (), False, True, "unsupported format")
    valid = _valid_utf8(prefix) if rule.requires_utf8 else _valid_signature(extension, prefix)
    mime_type = rule.mime_override or guessed_mime
    reason = None if valid else rule.invalid_reason
    return FileClassification(rule.kind, mime_type, rule.processors, True, valid, reason)


def classify_fd(name: str, descriptor: int) -> FileClassification:
    """Classify one already-open file without another path resolution."""
    try:
        prefix = os.pread(descriptor, 8192, 0)
    except OSError as error:
        guessed_mime = mimetypes.guess_type(name, strict=False)[0] or "application/octet-stream"
        return FileClassification("unknown", guessed_mime, (), False, False, sanitize_reason(error))
    return classify_bytes(name, prefix)
