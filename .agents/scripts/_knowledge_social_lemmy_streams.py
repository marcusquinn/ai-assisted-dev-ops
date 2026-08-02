#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Lemmy stream policy and snapshot checkpoint rules."""

from __future__ import annotations

from dataclasses import dataclass

from _knowledge_social_lemmy_identity import LemmyAdapterError

RETENTION_LIMIT = "home_instance_federation_permissions_and_operator_retention"


@dataclass(frozen=True)
class StreamSpec:
    resource_kind: str
    activity_mode: str
    pagination: str = "versioned"
    incremental: bool = True
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "federation_permissions_and_retention_bound"
    cost_units: int = 2


def _incremental(resource_kind: str, activity_mode: str) -> StreamSpec:
    return StreamSpec(resource_kind, activity_mode)


def _snapshot(resource_kind: str, activity_mode: str) -> StreamSpec:
    return StreamSpec(resource_kind, activity_mode, "snapshot", False)


STREAMS = {
    "authored_posts": _incremental("post", "content_author"),
    "authored_comments": _incremental("comment", "content_author"),
    "saved_posts": _snapshot("post", "selected_account"),
    "saved_comments": _snapshot("comment", "selected_account"),
    "liked_posts": _snapshot("post", "selected_account"),
    "liked_comments": _snapshot("comment", "selected_account"),
    "notifications": _incremental("notification", "selected_account"),
    "replies": _incremental("reply", "selected_account"),
    "mentions": _incremental("mention", "selected_account"),
    "subscriptions": _snapshot("community", "selected_account"),
    "multicommunities": _snapshot("multicommunity", "selected_account"),
}
V4_STREAMS = frozenset(STREAMS) - {"replies", "mentions"}
V3_STREAMS = frozenset(STREAMS) - {"notifications", "multicommunities"}


def initial_overlap_cutoff(
    stream: str, backfill_complete: bool, watermark: str | None
) -> str | None:
    if STREAMS[stream].incremental and backfill_complete:
        return watermark
    return None


def require_overlap_policy(stream: str, overlap_cutoff: str | None) -> None:
    if not STREAMS[stream].incremental and overlap_cutoff is not None:
        raise LemmyAdapterError("Lemmy snapshot cannot carry an overlap cutoff")


def checkpoint_watermark(
    stream: str, previous: str | None, candidate: str | None
) -> str | None:
    if not STREAMS[stream].incremental or candidate is None:
        return previous
    return candidate
