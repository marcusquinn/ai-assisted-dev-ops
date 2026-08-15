"""Bounded context values for performance-store persistence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class QuarantineContext:
    source: str
    account_ref: str
    source_event_id: str
    reason: str
    evidence_ref: str
    recorded_at: str
    details: dict[str, Any]


@dataclass(frozen=True)
class GovernanceContext:
    event: dict[str, Any]
    record_ref: str
    subject_id: str | None
    source: str
    account_ref: str
    observed_at: str
    recorded_at: str
    evidence_ref: str


@dataclass(frozen=True)
class SourceStateContext:
    adapter: str
    header: dict[str, Any]
    evidence_ref: str
    recorded_at: str
    partial: bool


@dataclass(frozen=True)
class EvidenceWriteContext:
    source: str
    account_ref: str
    digest: str
    suffix: str
    raw_bytes: bytes


@dataclass(frozen=True)
class EventInsertContext:
    event: dict[str, Any]
    header: dict[str, Any]
    evidence_ref: str
    recorded_at: str
