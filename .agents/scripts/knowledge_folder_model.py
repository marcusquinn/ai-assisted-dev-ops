#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared value objects for recursive folder ingestion."""

from __future__ import annotations

import time
from dataclasses import dataclass
from pathlib import Path


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
        limits_reached = (
            self.remaining_items <= 0,
            size_bytes > self.remaining_bytes,
            time.monotonic() >= self.deadline,
        )
        if any(limits_reached):
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


@dataclass(frozen=True)
class StoredBlob:
    """A blob reference plus whether this transaction created its payload."""

    reference: str
    path: Path
    created: bool


@dataclass(frozen=True)
class EvidenceInput:
    """Canonical input shared by top-level files and generated child evidence."""

    name: str
    digest: str
    size_bytes: int
    kind: str
    mime_type: str
    processors: tuple[str, ...] = ()
    descriptor: int | None = None
    data: bytes | None = None
