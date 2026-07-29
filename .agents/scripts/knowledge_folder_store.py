#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Canonical raw storage and local enrichment projections for folder imports."""

from __future__ import annotations

import email.policy
import fcntl
import json
import os
import re
import shutil
import tempfile
import time
from contextlib import contextmanager
from dataclasses import dataclass
from email.message import Message
from email.parser import BytesParser
from pathlib import Path
from typing import Any, Iterator

from knowledge_folder_types import (
    atomic_write_json,
    fsync_directory,
    sha256_bytes,
    sha256_file,
    source_id_for_digest,
)
from knowledge_source_contract import SourceMetaInput, build_source_meta, validate_source_meta


SOURCE_ID = re.compile(r"^[a-z0-9][a-z0-9-]{2,79}$")
MBOX_SEPARATOR = re.compile(
    rb"^From \S+ (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) "
    rb"(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) "
    rb"[ 0-3]\d \d{2}:\d{2}(?::\d{2})?(?: [^\r\n ]+)? \d{4}\r?$"
)
TEXT_EXTENSIONS = {
    ".csv", ".htm", ".html", ".json", ".jsonl", ".log", ".md", ".rst",
    ".tex", ".tsv", ".txt", ".xml", ".yaml", ".yml",
}


class EvidenceProcessingError(ValueError):
    """A single item's projection failed after its raw evidence was preserved."""


@dataclass
class ExpansionBudget:
    """Remaining child evidence budget shared by mailbox and attachment expansion."""

    remaining_items: int
    remaining_bytes: int
    deadline: float
    consumed_items: int = 0
    consumed_bytes: int = 0
    stopped: bool = False

    def consume(self, size_bytes: int) -> bool:
        if (
            self.remaining_items <= 0
            or size_bytes > self.remaining_bytes
            or time.monotonic() >= self.deadline
        ):
            self.stopped = True
            return False
        self.remaining_items -= 1
        self.remaining_bytes -= size_bytes
        self.consumed_items += 1
        self.consumed_bytes += size_bytes
        return True


@dataclass(frozen=True)
class StoredEvidence:
    """Result of resolving raw bytes to one canonical source."""

    source_id: str
    evidence_id: str
    digest: str
    reused: bool
    relations: tuple[dict[str, str], ...] = ()
    budget_stopped: bool = False


class SourceStore:
    """Persist immutable evidence before advancing a folder checkpoint."""

    def __init__(
        self,
        knowledge_root: Path,
        corpus_id: str,
        scripts_dir: Path,
        blob_threshold: int = 31_457_280,
    ) -> None:
        self.knowledge_root = knowledge_root
        self.sources_dir = knowledge_root / "sources"
        self.index_dir = knowledge_root / "index"
        self.corpus_id = corpus_id
        self.scripts_dir = scripts_dir
        self.blob_threshold = blob_threshold
        for directory in (self.sources_dir, self.index_dir):
            if directory.is_symlink() or not directory.is_dir():
                raise ValueError("canonical knowledge directory is unavailable or unsafe")
        self.by_digest = self._source_index()

    def _source_index(self) -> dict[str, tuple[str, str]]:
        index: dict[str, tuple[str, str]] = {}
        for source_dir in self.sources_dir.iterdir():
            if source_dir.name.startswith("."):
                continue
            meta_path = source_dir / "meta.json"
            if source_dir.is_symlink() or not source_dir.is_dir() or meta_path.is_symlink() or not meta_path.is_file():
                continue
            try:
                meta = json.loads(meta_path.read_text(encoding="utf-8"))
            except (OSError, UnicodeError, json.JSONDecodeError):
                continue
            digest = meta.get("content_sha256") or meta.get("sha256")
            source_id = source_dir.name
            evidence_id = meta.get("evidence_id", "")
            provenance = meta.get("provenance")
            try:
                validate_source_meta(meta)
            except (TypeError, ValueError):
                continue
            if not (
                SOURCE_ID.fullmatch(source_id)
                and meta.get("id") == source_id
                and isinstance(digest, str)
                and re.fullmatch(r"[0-9a-f]{64}", digest)
                and isinstance(evidence_id, str)
                and meta.get("corpus_id") == self.corpus_id
                and isinstance(provenance, dict)
                and provenance.get("content_sha256") == digest
            ):
                continue
            payload = self._canonical_payload(source_dir, meta, digest)
            if payload is None:
                continue
            index.setdefault(digest, (source_id, evidence_id))
        return index

    def _canonical_payload(self, source_dir: Path, meta: dict[str, Any], digest: str) -> Path | None:
        blob_ref = meta.get("blob_path")
        if blob_ref is not None:
            if blob_ref != f"knowledge-blobs:sha256:{digest}":
                return None
            try:
                blob_dir = _secure_directory(
                    Path.home(), ".aidevops", ".agent-workspace", "knowledge-blobs",
                    "folder-imports", source_dir.name, create=False,
                )
            except EvidenceProcessingError:
                return None
            candidates = _payload_candidates(blob_dir, meta.get("raw_path"))
        else:
            candidates = _payload_candidates(source_dir, meta.get("raw_path"))
        if len(candidates) != 1:
            return None
        payload = candidates[0]
        size_bytes = meta.get("size_bytes")
        try:
            if not isinstance(size_bytes, int) or payload.stat(follow_symlinks=False).st_size != size_bytes:
                return None
            if sha256_file(payload) != digest:
                return None
        except OSError:
            return None
        return payload

    def import_file(
        self,
        name: str,
        descriptor: int,
        size_bytes: int,
        digest: str,
        kind: str,
        mime_type: str,
        processors: tuple[str, ...],
        budget: ExpansionBudget,
    ) -> StoredEvidence:
        """Import from the exact descriptor that was classified and hashed."""
        data: bytes | None = None
        if kind in {"email", "export"} or Path(name).suffix.lower() in TEXT_EXTENSIONS:
            data = _read_descriptor(descriptor)
        result = self._store(name, digest, size_bytes, kind, mime_type, descriptor, data)
        self._ensure_enrichment(result.source_id, kind, mime_type, processors)
        try:
            if kind == "email" and data is not None:
                message_bytes = self._email_bytes(Path(name).suffix.lower(), data)
                relations = self._enrich_email(result.source_id, message_bytes, budget)
                return StoredEvidence(
                    result.source_id, result.evidence_id, digest, result.reused,
                    tuple(relations), budget.stopped,
                )
            if kind == "export" and data is not None:
                relations = self._expand_mailbox(data, result.source_id, budget)
                return StoredEvidence(
                    result.source_id, result.evidence_id, digest, result.reused,
                    tuple(relations), budget.stopped,
                )
            if kind == "document" and data is not None:
                self._ensure_text_projection(result.source_id, data.decode("utf-8"))
        except (LookupError, UnicodeError, ValueError, TypeError) as error:
            raise EvidenceProcessingError("content projection failed") from error
        return result

    @contextmanager
    def _digest_lock(self, digest: str) -> Iterator[None]:
        lock_dir = _secure_directory(self.index_dir, "folder-imports", "digest-locks")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(lock_dir / f"{digest}.lock", flags, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)

    def _store(
        self,
        name: str,
        digest: str,
        size_bytes: int,
        kind: str,
        mime_type: str,
        source_descriptor: int | None,
        data: bytes | None,
    ) -> StoredEvidence:
        with self._digest_lock(digest):
            self.by_digest.update(self._source_index())
            existing = self.by_digest.get(digest)
            if existing is not None:
                return StoredEvidence(existing[0], existing[1], digest, True)
            source_id = source_id_for_digest(kind, digest)
            source_dir = self.sources_dir / source_id
            if source_dir.exists():
                source_id = f"{source_id}-{digest[24:32]}"
                source_dir = self.sources_dir / source_id
            staging = Path(tempfile.mkdtemp(prefix=f".{source_id}.staging-", dir=self.sources_dir))
            os.chmod(staging, 0o700)
            try:
                blob_ref = None
                if size_bytes >= self.blob_threshold:
                    blob_ref = self._store_blob(source_id, digest, source_descriptor, data)
                else:
                    destination = staging / "raw.bin"
                    _write_payload(destination, source_descriptor, data)
                    if sha256_file(destination) != digest:
                        raise EvidenceProcessingError("stored evidence digest does not match inventory")
                meta = build_source_meta(
                    SourceMetaInput(
                        source_id=source_id,
                        corpus_id=self.corpus_id,
                        connector_id="local-folder",
                        source_uri=f"local:{source_id}",
                        content_sha256=digest,
                        size_bytes=size_bytes,
                        kind=kind,
                        sensitivity="internal",
                        trust="unverified",
                        ingested_at=_utc_now(),
                        blob_ref=blob_ref,
                    )
                )
                meta["media_type"] = mime_type
                meta["raw_path"] = "raw.bin"
                atomic_write_json(staging / "meta.json", meta)
                fsync_directory(staging)
                staging.replace(source_dir)
                fsync_directory(self.sources_dir)
            except Exception:
                shutil.rmtree(staging, ignore_errors=True)
                raise
            self.by_digest[digest] = (source_id, str(meta["evidence_id"]))
            return StoredEvidence(source_id, str(meta["evidence_id"]), digest, False)

    def _store_blob(
        self,
        source_id: str,
        digest: str,
        source_descriptor: int | None,
        data: bytes | None,
    ) -> str:
        blob_root = _secure_directory(
            Path.home(), ".aidevops", ".agent-workspace", "knowledge-blobs", "folder-imports"
        )
        blob_dir = _secure_directory(blob_root, source_id)
        destination = blob_dir / "raw.bin"
        _write_payload(destination, source_descriptor, data)
        if sha256_file(destination) != digest:
            destination.unlink(missing_ok=True)
            raise EvidenceProcessingError("stored blob digest does not match inventory")
        fsync_directory(blob_dir)
        return f"knowledge-blobs:sha256:{digest}"

    def _ensure_text_projection(self, source_id: str, content: str) -> None:
        path = self.sources_dir / source_id / "text.txt"
        if not path.exists():
            _write_payload(path, None, content.encode("utf-8"))

    def _ensure_enrichment(
        self, source_id: str, kind: str, mime_type: str, processors: tuple[str, ...]
    ) -> None:
        jobs: list[dict[str, str]] = []
        for processor in processors:
            status = "completed" if processor in {"metadata", "email-parse", "mailbox-expand"} else "queued"
            helper = {
                "ocr": "paddleocr-helper.sh",
                "text-extraction": "document-extraction-helper.sh",
                "transcription": "transcription-helper.sh",
            }.get(processor)
            if helper and not (self.scripts_dir / helper).is_file():
                status = "unavailable"
            if processor == "keyframes" and shutil.which("ffmpeg") is None:
                status = "unavailable"
            jobs.append({"processor": processor, "status": status})
        atomic_write_json(
            self.sources_dir / source_id / "enrichment.json",
            {
                "version": 1,
                "authority": "projection",
                "source_id": source_id,
                "kind": kind,
                "media_type": mime_type,
                "jobs": jobs,
            },
        )

    def _email_bytes(self, extension: str, data: bytes) -> bytes:
        if extension != ".emlx":
            return data
        length_line, separator, payload = data.partition(b"\n")
        if not separator or not length_line.isdigit():
            raise EvidenceProcessingError("emlx length header is malformed")
        message_length = int(length_line)
        if message_length > len(payload):
            raise EvidenceProcessingError("emlx message is truncated")
        return payload[:message_length]

    def _enrich_email(
        self, parent_id: str, raw_message: bytes, budget: ExpansionBudget
    ) -> list[dict[str, str]]:
        message = BytesParser(policy=email.policy.default).parsebytes(raw_message)
        relations = self._store_attachments(parent_id, message, budget)
        text_body = _message_text(message)
        if text_body:
            self._ensure_text_projection(parent_id, text_body)
        self._extend_meta(
            parent_id,
            {
                "from": str(message.get("From", "")),
                "to": str(message.get("To", "")),
                "cc": str(message.get("Cc", "")),
                "date": str(message.get("Date", "")),
                "subject": str(message.get("Subject", "")),
                "message_id": str(message.get("Message-ID", "")),
                "attachments": relations,
            },
        )
        return relations

    def _store_attachments(
        self, parent_id: str, message: Message, budget: ExpansionBudget
    ) -> list[dict[str, str]]:
        relations: list[dict[str, str]] = []
        for index, part in enumerate(message.iter_attachments()):
            filename = part.get_filename() or f"attachment-{index + 1}.bin"
            payload = _attachment_bytes(part)
            if payload is None:
                relations.append({
                    "relationship": "attachment",
                    "status": "unsupported",
                    "filename": Path(filename).name,
                    "content_type": part.get_content_type(),
                })
                continue
            if not budget.consume(len(payload)):
                relations.append({"relationship": "attachment", "status": "budget-stopped"})
                break
            digest = sha256_bytes(payload)
            result = self._store(
                filename, digest, len(payload), "attachment",
                part.get_content_type() or "application/octet-stream", None, payload,
            )
            self._extend_meta(
                result.source_id,
                {
                    "parent_sources": [parent_id],
                    "attachment_filename": Path(filename).name,
                    "content_type": part.get_content_type(),
                },
            )
            relations.append({"source_id": result.source_id, "relationship": "attachment"})
        return relations

    def _expand_mailbox(
        self, data: bytes, parent_id: str, budget: ExpansionBudget
    ) -> list[dict[str, str]]:
        relations: list[dict[str, str]] = []
        for index, raw_message in enumerate(_mbox_messages(data)):
            if not budget.consume(len(raw_message)):
                relations.append({"relationship": "mailbox-message", "status": "budget-stopped"})
                break
            digest = sha256_bytes(raw_message)
            result = self._store(
                f"message-{index + 1}.eml", digest, len(raw_message), "email",
                "message/rfc822", None, raw_message,
            )
            children = self._enrich_email(result.source_id, raw_message, budget)
            self._extend_meta(result.source_id, {"parent_sources": [parent_id]})
            relations.append({"source_id": result.source_id, "relationship": "mailbox-message"})
            relations.extend(children)
        self._extend_meta(parent_id, {"children": relations})
        return relations

    def _extend_meta(self, source_id: str, fields: dict[str, Any]) -> None:
        if not SOURCE_ID.fullmatch(source_id):
            raise EvidenceProcessingError("source identity is invalid")
        with self._meta_lock(source_id):
            source_dir = self.sources_dir / source_id
            meta_path = source_dir / "meta.json"
            if source_dir.is_symlink() or meta_path.is_symlink():
                raise EvidenceProcessingError("source metadata path is unsafe")
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            if meta.get("id") != source_id:
                raise EvidenceProcessingError("source metadata identity conflicts")
            merged = dict(fields)
            for key in ("attachments", "children", "parent_sources"):
                if key not in fields:
                    continue
                existing = meta.get(key, [])
                requested = fields.get(key, [])
                if not isinstance(existing, list) or not isinstance(requested, list):
                    raise EvidenceProcessingError("source relationship metadata is invalid")
                values = {json.dumps(value, sort_keys=True): value for value in (*existing, *requested)}
                merged[key] = [values[value] for value in sorted(values)]
            meta.update(merged)
            atomic_write_json(meta_path, meta)

    @contextmanager
    def _meta_lock(self, source_id: str) -> Iterator[None]:
        lock_dir = _secure_directory(self.index_dir, "folder-imports", "meta-locks")
        flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(lock_dir / f"{source_id}.lock", flags, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            yield
        finally:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            os.close(descriptor)


def _read_descriptor(descriptor: int) -> bytes:
    duplicate = os.dup(descriptor)
    try:
        os.lseek(duplicate, 0, os.SEEK_SET)
        with os.fdopen(duplicate, "rb", closefd=True) as handle:
            duplicate = -1
            return handle.read()
    finally:
        if duplicate >= 0:
            os.close(duplicate)


def _write_payload(path: Path, source_descriptor: int | None, data: bytes | None) -> None:
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.tmp-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "wb", closefd=True) as target:
            descriptor = -1
            if source_descriptor is not None:
                duplicate = os.dup(source_descriptor)
                try:
                    os.lseek(duplicate, 0, os.SEEK_SET)
                    with os.fdopen(duplicate, "rb", closefd=True) as source:
                        duplicate = -1
                        shutil.copyfileobj(source, target, 1024 * 1024)
                finally:
                    if duplicate >= 0:
                        os.close(duplicate)
            else:
                target.write(data or b"")
            target.flush()
            os.fsync(target.fileno())
        temporary.replace(path)
        fsync_directory(path.parent)
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _attachment_bytes(part: Message) -> bytes | None:
    if part.get_content_type() == "message/rfc822":
        return None
    payload = part.get_payload(decode=True)
    if payload is not None:
        return payload
    return None


def _message_text(message: Message) -> str:
    plain = message.get_body(preferencelist=("plain",))
    if plain is None:
        return ""
    content = plain.get_content()
    return content if isinstance(content, str) else ""


def _mbox_messages(data: bytes) -> Iterator[bytes]:
    position = 0
    while position < len(data):
        envelope_end = data.find(b"\n", position)
        if envelope_end < 0:
            raise EvidenceProcessingError("mailbox envelope is truncated")
        envelope = data[position:envelope_end]
        if MBOX_SEPARATOR.fullmatch(envelope) is None:
            raise EvidenceProcessingError("mailbox envelope is malformed")
        message_start = envelope_end + 1
        header_end, body_start = _message_header_boundary(data, message_start)
        content_length = _content_length(data[message_start:header_end])
        if content_length is not None:
            message_end = body_start + content_length
            if message_end > len(data):
                raise EvidenceProcessingError("mailbox content length exceeds available bytes")
            next_position = _separator_after_content(data, message_end)
        else:
            next_position = _next_mbox_separator(data, message_start)
            message_end = next_position if next_position is not None else len(data)
        yield data[message_start:message_end]
        if next_position is None:
            return
        position = next_position


def _message_header_boundary(data: bytes, start: int) -> tuple[int, int]:
    crlf = data.find(b"\r\n\r\n", start)
    lf = data.find(b"\n\n", start)
    candidates = [(crlf, 4), (lf, 2)]
    present = [(offset, width) for offset, width in candidates if offset >= 0]
    if not present:
        return start, start
    offset, width = min(present)
    return offset, offset + width


def _content_length(headers: bytes) -> int | None:
    matches = re.findall(rb"(?im)^Content-Length:[ \t]*(\d+)[ \t]*\r?$", headers)
    if not matches:
        return None
    if len(matches) != 1:
        raise EvidenceProcessingError("mailbox content length is ambiguous")
    return int(matches[0])


def _separator_after_content(data: bytes, position: int) -> int | None:
    if position >= len(data):
        return None
    if data[position:] in {b"\n", b"\r\n"}:
        return None
    candidates = (position, position + 1, position + 2)
    for candidate in candidates:
        if candidate >= len(data):
            continue
        if candidate > position and data[position:candidate] not in {b"\n", b"\r\n"}:
            continue
        line_end = data.find(b"\n", candidate)
        if line_end >= 0 and MBOX_SEPARATOR.fullmatch(data[candidate:line_end]) is not None:
            return candidate
    raise EvidenceProcessingError("mailbox content length does not end at an envelope")


def _next_mbox_separator(data: bytes, start: int) -> int | None:
    position = start
    while position < len(data):
        line_end = data.find(b"\n", position)
        if line_end < 0:
            return None
        if MBOX_SEPARATOR.fullmatch(data[position:line_end]) is not None:
            return position
        position = line_end + 1
    return None


def _payload_candidates(directory: Path, raw_hint: object) -> list[Path]:
    if directory.is_symlink() or not directory.is_dir():
        return []
    if isinstance(raw_hint, str) and raw_hint == Path(raw_hint).name:
        candidate = directory / raw_hint
        if not candidate.is_symlink() and candidate.is_file():
            return [candidate]
        return []
    projections = {"body.html", "enrichment.json", "meta.json", "source.md", "text.txt"}
    return [
        candidate for candidate in directory.iterdir()
        if candidate.name not in projections and not candidate.is_symlink() and candidate.is_file()
    ]


def _secure_directory(base: Path, *components: str, create: bool = True) -> Path:
    if base.is_symlink() or not base.is_dir():
        raise EvidenceProcessingError("storage root is unsafe")
    current = base
    missing = False
    for component in components:
        current = current / component
        if missing:
            continue
        if not current.exists():
            if not create:
                missing = True
                continue
            current.mkdir(mode=0o700)
        if current.is_symlink() or not current.is_dir():
            raise EvidenceProcessingError("storage directory is unsafe")
    return current


def _utc_now() -> str:
    from datetime import datetime, timezone

    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
