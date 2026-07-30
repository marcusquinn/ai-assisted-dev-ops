#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Single-item processing for recursive folder ingestion."""

from __future__ import annotations

import os
from dataclasses import dataclass
from typing import Any

from knowledge_folder_manifest import (
    FolderImportError,
    ManifestEntry,
    aliases_for_digest,
    record,
)
from knowledge_folder_model import EvidenceInput, EvidenceProcessingError, ExpansionBudget
from knowledge_folder_store import SourceStore
from knowledge_folder_types import FileClassification, classify_fd, sha256_fd
from knowledge_folder_walk import InventoryItem


@dataclass
class FileProcessor:
    """Process one retained descriptor and publish its manifest observation."""

    manifest: dict[str, Any]
    previous_entries: dict[str, Any]
    store: SourceStore
    dry_run: bool
    budget: ExpansionBudget

    def process(self, item: InventoryItem) -> None:
        if item.descriptor is None:
            raise FolderImportError("regular file descriptor is unavailable")
        classification = classify_fd(item.name, item.descriptor)
        if self._record_rejection(item, classification):
            return
        digest = sha256_fd(item.descriptor)
        before = _identity(item.info)
        after = _identity(os.fstat(item.descriptor))
        if before != after:
            self._record_failure(item, classification.kind, "file changed during scan")
            return
        aliases = aliases_for_digest(self.previous_entries, item.relative, digest)
        existing = self.store.source_for_digest(digest)
        if self.dry_run:
            self._record_plan(item, classification, digest, aliases, existing)
            return
        if self._is_unchanged(item, digest, existing):
            self._record_unchanged(item, classification, digest, aliases, existing)
            return
        self._import(item, classification, digest, aliases, after)

    def _record_rejection(self, item: InventoryItem, classification: FileClassification) -> bool:
        if not classification.supported:
            record(
                self.manifest, item.relative,
                ManifestEntry("unsupported", item.info.st_size, reason=classification.reason),
            )
            return True
        if not classification.valid:
            self._record_failure(item, classification.kind, classification.reason)
            return True
        return False

    def _record_failure(self, item: InventoryItem, kind: str, reason: object) -> None:
        record(self.manifest, item.relative, ManifestEntry("failed", item.info.st_size, kind, reason=reason))

    def _record_plan(
        self,
        item: InventoryItem,
        classification: FileClassification,
        digest: str,
        aliases: list[str],
        existing: tuple[str, str] | None,
    ) -> None:
        status = "unchanged" if existing is not None else "planned"
        record(
            self.manifest,
            item.relative,
            ManifestEntry(
                status, item.info.st_size, classification.kind, digest,
                source_id=existing[0] if existing else None, aliases=aliases,
            ),
        )

    def _is_unchanged(
        self, item: InventoryItem, digest: str, existing: tuple[str, str] | None
    ) -> bool:
        previous = self.previous_entries.get(item.relative, {})
        checks = (
            existing is not None,
            isinstance(previous, dict),
            previous.get("status") in {"imported", "unchanged"},
            previous.get("sha256") == digest,
            existing is not None and previous.get("source_id") == existing[0],
        )
        return all(checks)

    def _record_unchanged(
        self,
        item: InventoryItem,
        classification: FileClassification,
        digest: str,
        aliases: list[str],
        existing: tuple[str, str] | None,
    ) -> None:
        if existing is None:
            raise FolderImportError("unchanged evidence identity is unavailable")
        previous = self.previous_entries[item.relative]
        record(
            self.manifest,
            item.relative,
            ManifestEntry(
                "unchanged", item.info.st_size, classification.kind, digest,
                source_id=existing[0], evidence_id=existing[1], aliases=aliases,
                relations=tuple(previous.get("relations", [])),
            ),
        )

    def _import(
        self,
        item: InventoryItem,
        classification: FileClassification,
        digest: str,
        aliases: list[str],
        expected: tuple[int, int, int],
    ) -> None:
        evidence = EvidenceInput(
            item.name, digest, item.info.st_size, classification.kind,
            classification.mime_type, classification.processors, descriptor=item.descriptor,
        )
        try:
            result = self.store.import_file(evidence, self.budget)
        except EvidenceProcessingError as error:
            preserved = self.store.by_digest.get(digest)
            record(
                self.manifest,
                item.relative,
                ManifestEntry(
                    "failed", item.info.st_size, classification.kind, digest, error,
                    preserved[0] if preserved else None, preserved[1] if preserved else None, aliases,
                ),
            )
            return
        changed = _identity(os.fstat(item.descriptor)) != expected
        status = "failed" if changed else (
            "budget-stopped" if result.budget_stopped else ("unchanged" if result.reused else "imported")
        )
        entry = ManifestEntry(
            status, item.info.st_size, classification.kind, digest,
            reason="file changed while evidence was copied" if changed else None,
            source_id=result.source_id, evidence_id=result.evidence_id,
            aliases=aliases, relations=result.relations,
        )
        record(self.manifest, item.relative, entry)


def _identity(info: os.stat_result) -> tuple[int, int, int]:
    return info.st_ino, info.st_size, info.st_mtime_ns
