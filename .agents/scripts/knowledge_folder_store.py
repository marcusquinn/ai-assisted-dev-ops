#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Canonical raw storage and local enrichment projections for folder imports."""

from __future__ import annotations

import shutil
import tempfile
from dataclasses import replace
from pathlib import Path
from typing import Any

from knowledge_folder_email import EmailMixin
from knowledge_folder_model import (
    EvidenceInput,
    EvidenceProcessingError,
    ExpansionBudget,
    StoredBlob,
    StoredEvidence,
)
from knowledge_folder_projection import ProjectionMixin
from knowledge_folder_source_index import SourceIndexMixin
from knowledge_folder_storage import (
    StorageMixin,
    _read_descriptor,
    _remove_blob,
    _secure_directory,
    _utc_now,
    _write_payload,
)
from knowledge_folder_types import (
    TEXT_EXTENSIONS,
    atomic_write_json,
    fsync_directory,
    sha256_file,
    source_id_for_digest,
)
from knowledge_source_contract import SourceMetaInput, build_source_meta


SYNCHRONOUS_PROCESSORS = {
    "document": ("text-extraction",),
    "email": ("email-parse",),
    "export": ("mailbox-expand",),
}


class SourceStore(SourceIndexMixin, StorageMixin, ProjectionMixin, EmailMixin):
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

    def import_file(self, request: EvidenceInput | str, *legacy: Any) -> StoredEvidence:
        """Import a request, accepting the original positional API for compatibility."""
        evidence, budget = _coerce_import(request, legacy)
        prepared = _prepare_evidence(evidence)
        result = self._store(prepared)
        synchronous = SYNCHRONOUS_PROCESSORS.get(prepared.kind, ())
        try:
            relations, completed = self._run_synchronous(prepared, result, budget)
            dispositions = {processor: "completed" for processor in completed}
            self._ensure_enrichment(
                result.source_id, prepared.kind, prepared.mime_type, prepared.processors, dispositions
            )
        except (LookupError, OSError, UnicodeError, ValueError, TypeError) as error:
            self._mark_projection_failure(prepared, result, synchronous)
            raise EvidenceProcessingError("content projection failed") from error
        return replace(result, relations=tuple(relations), budget_stopped=budget.stopped)

    def _mark_projection_failure(
        self, evidence: EvidenceInput, result: StoredEvidence, processors: tuple[str, ...]
    ) -> None:
        failed = {processor: "failed" for processor in processors}
        try:
            self._ensure_enrichment(
                result.source_id, evidence.kind, evidence.mime_type, evidence.processors, failed
            )
        except (LookupError, OSError, UnicodeError, ValueError, TypeError) as error:
            raise EvidenceProcessingError("failed enrichment status could not be persisted") from error

    def _run_synchronous(
        self, evidence: EvidenceInput, result: StoredEvidence, budget: ExpansionBudget
    ) -> tuple[list[dict[str, str]], set[str]]:
        if evidence.kind == "email" and evidence.data is not None:
            message_bytes = self._email_bytes(Path(evidence.name).suffix.lower(), evidence.data)
            return self._enrich_email(result.source_id, message_bytes, budget), {"email-parse"}
        if evidence.kind == "export" and evidence.data is not None:
            return self._expand_mailbox(evidence.data, result.source_id, budget), {"mailbox-expand"}
        if evidence.kind == "document" and evidence.data is not None:
            self._ensure_text_projection(result.source_id, evidence.data.decode("utf-8"))
            return [], {"text-extraction"}
        return [], set()

    def _store(self, evidence: EvidenceInput) -> StoredEvidence:
        with self._digest_lock(evidence.digest):
            existing = self._existing_source(evidence.digest)
            if existing is not None:
                return StoredEvidence(existing[0], existing[1], evidence.digest, True)
            source_id, source_dir = self._source_target(evidence)
            staging = Path(tempfile.mkdtemp(prefix=f".{source_id}.staging-", dir=self.sources_dir))
            os_mode_private(staging)
            blob: StoredBlob | None = None
            source_published = False
            try:
                blob = self._stage_evidence(staging, source_id, evidence)
                blob_ref = blob.reference if blob is not None else None
                meta = self._source_meta(source_id, evidence, blob_ref)
                atomic_write_json(staging / "meta.json", meta)
                fsync_directory(staging)
                staging.replace(source_dir)
                source_published = True
                fsync_directory(self.sources_dir)
            except Exception:
                shutil.rmtree(staging, ignore_errors=True)
                if blob is not None and blob.created and not source_published:
                    _remove_blob(blob.path)
                raise
            evidence_id = str(meta["evidence_id"])
            self.by_digest[evidence.digest] = (source_id, evidence_id)
            return StoredEvidence(source_id, evidence_id, evidence.digest, False)

    def _source_target(self, evidence: EvidenceInput) -> tuple[str, Path]:
        source_id = source_id_for_digest(evidence.kind, evidence.digest)
        source_dir = self.sources_dir / source_id
        if source_dir.exists():
            source_id = f"{source_id}-{evidence.digest[24:32]}"
            source_dir = self.sources_dir / source_id
        return source_id, source_dir

    def _stage_evidence(
        self, staging: Path, source_id: str, evidence: EvidenceInput
    ) -> StoredBlob | None:
        if evidence.size_bytes >= self.blob_threshold:
            return self._store_blob(source_id, evidence)
        destination = staging / "raw.bin"
        _write_payload(destination, evidence.descriptor, evidence.data)
        if sha256_file(destination) != evidence.digest:
            raise EvidenceProcessingError("stored evidence digest does not match inventory")
        return None

    def _source_meta(
        self, source_id: str, evidence: EvidenceInput, blob_ref: str | None
    ) -> dict[str, Any]:
        meta = build_source_meta(
            SourceMetaInput(
                source_id=source_id,
                corpus_id=self.corpus_id,
                connector_id="local-folder",
                source_uri=f"local:{source_id}",
                content_sha256=evidence.digest,
                size_bytes=evidence.size_bytes,
                kind=evidence.kind,
                sensitivity="internal",
                trust="unverified",
                ingested_at=_utc_now(),
                blob_ref=blob_ref,
            )
        )
        meta["media_type"] = evidence.mime_type
        meta["raw_path"] = "raw.bin"
        return meta


def _coerce_import(
    request: EvidenceInput | str, legacy: tuple[Any, ...]
) -> tuple[EvidenceInput, ExpansionBudget]:
    if isinstance(request, EvidenceInput):
        if len(legacy) != 1 or not isinstance(legacy[0], ExpansionBudget):
            raise TypeError("EvidenceInput imports require one ExpansionBudget")
        return request, legacy[0]
    if len(legacy) != 7 or not isinstance(legacy[-1], ExpansionBudget):
        raise TypeError("legacy imports require descriptor, metadata, processors, and budget")
    descriptor, size_bytes, digest, kind, mime_type, processors, budget = legacy
    evidence = EvidenceInput(
        request, digest, size_bytes, kind, mime_type, tuple(processors), descriptor=descriptor
    )
    return evidence, budget


def _prepare_evidence(evidence: EvidenceInput) -> EvidenceInput:
    needs_data = evidence.kind in {"email", "export"} or Path(evidence.name).suffix.lower() in TEXT_EXTENSIONS
    if evidence.data is None and needs_data:
        if evidence.descriptor is None:
            raise EvidenceProcessingError("evidence descriptor is unavailable")
        return replace(evidence, data=_read_descriptor(evidence.descriptor))
    return evidence


def os_mode_private(path: Path) -> None:
    path.chmod(0o700)
