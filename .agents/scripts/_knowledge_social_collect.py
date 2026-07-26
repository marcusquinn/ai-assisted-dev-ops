#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Provider-neutral state and persistence types for social collectors."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_lease import RunLease


class CollectionStreamSpec(Protocol):
    """Minimum stream policy consumed by shared collector persistence."""

    cost_units: int


@dataclass(frozen=True)
class CursorState:
    """Durable per-connection/per-stream checkpoint."""

    cursor: str | None
    watermark: str | None
    backfill_complete: bool


@dataclass(frozen=True)
class PageCheckpoint:
    """Checkpoint calculated from one successful provider page."""

    next_cursor: str | None
    watermark: str | None


@dataclass(frozen=True)
class ConnectionConfig:
    """Merged non-secret policy for an existing or new connection."""

    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


@dataclass(frozen=True)
class CollectionContext:
    """Validated state shared by one bounded collection invocation."""

    root: Path
    connection_id: str
    account: dict[str, Any]
    stream: str
    media_policy: str
    config: ConnectionConfig
    state: CursorState
    spec: CollectionStreamSpec
    lease: RunLease | None = None
    provider: str = ""


@dataclass(frozen=True)
class SuccessfulPage:
    """Validated page plus its next durable checkpoint and coverage facts."""

    payload: dict[str, Any]
    request: str
    archive: dict[str, Any]
    checkpoint: PageCheckpoint
    complete: bool
    budget_units: int
    retention_limit: str | None = None
    unavailable_reason: str | None = None
    coverage_status: str | None = None


@dataclass(frozen=True)
class TerminalDecision:
    """Sanitized handling policy for one terminal provider response."""

    output_status: str
    run_status: str
    failure_class: str
