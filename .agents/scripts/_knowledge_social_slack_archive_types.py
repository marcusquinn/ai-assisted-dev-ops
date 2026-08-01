#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Data contracts for one bounded Slack administrator export import."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from _knowledge_social_slack_provider import ProfileConfig


@dataclass(frozen=True)
class SlackArchiveRequest:
    """Operator-approved archive and bounded import policy."""

    path: Path
    connection_id: str
    expected_account_id: str
    exported_at: str
    profile: ProfileConfig
    max_bytes: int
    max_items: int


@dataclass(frozen=True)
class ParsedSlackArchive:
    """Validated filtered evidence plus one canonical Slack archive."""

    archive: dict[str, Any]
    evidence: bytes
    source_sha256: str
    evidence_sha256: str
    conversation_streams: tuple[str, ...]
    selected_members: int
    normalized_items: int
