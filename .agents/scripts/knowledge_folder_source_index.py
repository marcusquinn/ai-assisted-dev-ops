#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Canonical source discovery and validation for folder ingestion."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any

from knowledge_folder_model import EvidenceProcessingError
from knowledge_folder_storage import _secure_directory
from knowledge_folder_types import sha256_file
from knowledge_source_contract import validate_source_meta


SOURCE_ID = re.compile(r"^[a-z0-9][a-z0-9-]{2,79}$")


class SourceIndexMixin:
    """Resolve canonical sources without trusting stale in-memory entries."""

    def _source_index(self) -> dict[str, tuple[str, str]]:
        index: dict[str, tuple[str, str]] = {}
        for source_dir in self.sources_dir.iterdir():
            record = self._source_record(source_dir)
            if record is not None:
                digest, source = record
                index.setdefault(digest, source)
        return index

    def _source_record(
        self, source_dir: Path, expected_digest: str | None = None
    ) -> tuple[str, tuple[str, str]] | None:
        meta_path = source_dir / "meta.json"
        unsafe = (
            source_dir.name.startswith("."), source_dir.is_symlink(), not source_dir.is_dir(),
            meta_path.is_symlink(), not meta_path.is_file(),
        )
        if any(unsafe):
            return None
        try:
            meta = json.loads(meta_path.read_text(encoding="utf-8"))
            validate_source_meta(meta)
        except (OSError, UnicodeError, json.JSONDecodeError, TypeError, ValueError):
            return None
        digest = meta.get("content_sha256") or meta.get("sha256")
        if not _valid_record_fields(meta, source_dir.name, self.corpus_id, expected_digest):
            return None
        if self._canonical_payload(source_dir, meta, digest) is None:
            return None
        return digest, (source_dir.name, meta["evidence_id"])

    def _canonical_payload(self, source_dir: Path, meta: dict[str, Any], digest: str) -> Path | None:
        blob_ref = meta.get("blob_path")
        if blob_ref is not None:
            if blob_ref != f"knowledge-blobs:sha256:{digest}":
                return None
            candidates = self._blob_payload_candidates(source_dir.name, meta.get("raw_path"))
        else:
            candidates = _payload_candidates(source_dir, meta.get("raw_path"))
        size_bytes = meta.get("size_bytes")
        if not isinstance(size_bytes, int):
            return None
        for payload in candidates:
            try:
                if payload.stat(follow_symlinks=False).st_size == size_bytes and sha256_file(payload) == digest:
                    return payload
            except OSError:
                continue
        return None

    def _blob_payload_candidates(self, source_id: str, raw_hint: object) -> list[Path]:
        try:
            blob_root = _secure_directory(
                Path.home(), ".aidevops", ".agent-workspace", "knowledge-blobs", create=False
            )
        except EvidenceProcessingError:
            return []
        try:
            namespaces = sorted(blob_root.iterdir(), key=lambda path: path.name)
        except OSError:
            return []
        candidates: list[Path] = []
        for namespace in namespaces:
            if not namespace.is_symlink() and namespace.is_dir():
                candidates.extend(_payload_candidates(namespace / source_id, raw_hint))
        return candidates

    def _existing_source(self, digest: str) -> tuple[str, str] | None:
        existing = self.by_digest.get(digest)
        if existing is not None:
            record = self._source_record(self.sources_dir / existing[0], digest)
            if record is not None:
                self.by_digest[digest] = record[1]
                return record[1]
            self.by_digest.pop(digest, None)
        suffix = digest[24:32]
        for prefix in ("folder", "attachment"):
            for source_id in (f"{prefix}-{digest[:24]}", f"{prefix}-{digest[:24]}-{suffix}"):
                record = self._source_record(self.sources_dir / source_id, digest)
                if record is not None:
                    self.by_digest[digest] = record[1]
                    return record[1]
        return None

    def source_for_digest(self, digest: str) -> tuple[str, str] | None:
        """Resolve a digest only after revalidating its canonical payload."""
        return self._existing_source(digest)


def _valid_record_fields(
    meta: dict[str, Any], source_id: str, corpus_id: str, expected_digest: str | None
) -> bool:
    digest = meta.get("content_sha256") or meta.get("sha256")
    provenance = meta.get("provenance")
    checks = (
        bool(SOURCE_ID.fullmatch(source_id)),
        meta.get("id") == source_id,
        _valid_digest(digest),
        expected_digest is None or digest == expected_digest,
        isinstance(meta.get("evidence_id"), str),
        meta.get("corpus_id") == corpus_id,
        isinstance(provenance, dict),
        isinstance(provenance, dict) and provenance.get("content_sha256") == digest,
    )
    return all(checks)


def _valid_digest(value: object) -> bool:
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def _payload_candidates(directory: Path, raw_hint: object) -> list[Path]:
    if directory.is_symlink() or not directory.is_dir():
        return []
    if isinstance(raw_hint, str) and raw_hint == Path(raw_hint).name:
        candidate = directory / raw_hint
        return [candidate] if not candidate.is_symlink() and candidate.is_file() else []
    projections = {"body.html", "enrichment.json", "meta.json", "source.md", "text.txt"}
    return [
        candidate for candidate in directory.iterdir()
        if candidate.name not in projections and not candidate.is_symlink() and candidate.is_file()
    ]
