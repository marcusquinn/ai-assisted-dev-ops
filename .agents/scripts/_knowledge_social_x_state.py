#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""X compatibility wrapper around provider-neutral collection state."""

from __future__ import annotations

from pathlib import Path
from typing import Any

from _knowledge_social_collect import CollectionContext, ConnectionConfig, ContextRequest
from _knowledge_social_collect_state import load_context as load_social_context
from _knowledge_social_x import PROVIDER, STREAMS


def load_context(
    root: Path,
    connection_id: str,
    account: dict[str, Any],
    stream: str,
    media_policy: str,
) -> CollectionContext:
    """Read the X connection policy and selected stream checkpoint."""
    return load_social_context(
        root,
        ContextRequest(PROVIDER, connection_id, account, stream, media_policy),
        STREAMS,
    )


__all__ = ("CollectionContext", "ConnectionConfig", "load_context")
