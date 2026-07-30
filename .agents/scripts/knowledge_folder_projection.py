#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Projection and relationship metadata for recursive folder ingestion."""

from __future__ import annotations

import fcntl
import json
import os
import shutil
from contextlib import contextmanager
from typing import Any, Iterator

from knowledge_folder_model import EvidenceProcessingError
from knowledge_folder_source_index import SOURCE_ID
from knowledge_folder_storage import _secure_directory, _write_payload
from knowledge_folder_types import atomic_write_json


PROCESSOR_HELPERS = {
    "ocr": "paddleocr-helper.sh",
    "text-extraction": "document-extraction-helper.sh",
    "transcription": "transcription-helper.sh",
}


class ProjectionMixin:
    """Maintain private enrichment and relationship projections under locks."""

    def _ensure_text_projection(self, source_id: str, content: str) -> None:
        path = self.sources_dir / source_id / "text.txt"
        if path.is_symlink() or (path.exists() and not path.is_file()):
            raise EvidenceProcessingError("text projection path is unsafe")
        if not path.exists():
            _write_payload(path, None, content.encode("utf-8"))

    def _ensure_enrichment(
        self,
        source_id: str,
        kind: str,
        mime_type: str,
        processors: tuple[str, ...],
        dispositions: dict[str, str] | None = None,
    ) -> None:
        requested = dispositions or {}
        path = self.sources_dir / source_id / "enrichment.json"
        with self._meta_lock(source_id):
            existing = _read_enrichment(path, source_id)
            jobs = {job["processor"]: job["status"] for job in existing.get("jobs", [])}
            for processor in processors:
                status = self._processor_status(processor, requested)
                if jobs.get(processor) != "completed":
                    jobs[processor] = status
            atomic_write_json(path, _enrichment_document(existing, source_id, kind, mime_type, jobs))

    def _processor_status(self, processor: str, dispositions: dict[str, str]) -> str:
        default_status = "completed" if processor == "metadata" else "queued"
        status = dispositions.get(processor, default_status)
        helper = PROCESSOR_HELPERS.get(processor)
        if helper and not (self.scripts_dir / helper).is_file():
            return "unavailable"
        if processor == "keyframes" and shutil.which("ffmpeg") is None:
            return "unavailable"
        return status

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
            meta.update(_merge_relationships(meta, fields))
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


def _merge_relationships(meta: dict[str, Any], fields: dict[str, Any]) -> dict[str, Any]:
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
    return merged


def _enrichment_document(
    existing: dict[str, Any], source_id: str, kind: str, mime_type: str,
    jobs: dict[str, str],
) -> dict[str, Any]:
    return {
        "version": 1,
        "authority": "projection",
        "source_id": source_id,
        "kind": existing.get("kind", kind),
        "media_type": existing.get("media_type", mime_type),
        "jobs": [
            {"processor": processor, "status": status}
            for processor, status in jobs.items()
        ],
    }


def _read_enrichment(path: object, source_id: str) -> dict[str, Any]:
    if not path.exists() and not path.is_symlink():
        return {}
    if path.is_symlink() or not path.is_file():
        raise EvidenceProcessingError("enrichment projection path is unsafe")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise EvidenceProcessingError("enrichment projection is invalid") from error
    jobs = value.get("jobs")
    if value.get("source_id") != source_id or not isinstance(jobs, list):
        raise EvidenceProcessingError("enrichment projection identity conflicts")
    valid_statuses = {"completed", "failed", "queued", "unavailable"}
    malformed = any(
        not isinstance(job, dict)
        or not isinstance(job.get("processor"), str)
        or job.get("status") not in valid_statuses
        for job in jobs
    )
    if malformed:
        raise EvidenceProcessingError("enrichment projection jobs are invalid")
    return value
