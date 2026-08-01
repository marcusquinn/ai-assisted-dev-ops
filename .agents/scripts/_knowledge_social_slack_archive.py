#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate and normalize one administrator-approved Slack JSON export."""

from __future__ import annotations

import hashlib
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_lease import social_now
from _knowledge_social_slack import PROVIDER
from _knowledge_social_slack_archive_select import select_archive_records
from _knowledge_social_slack_archive_types import (
    ParsedSlackArchive as ParsedSlackArchive,
    SlackArchiveRequest as SlackArchiveRequest,
)
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_normalize import (
    EXPORT_SOURCE,
    NormalizationBatch,
    PageContext,
    canonical_observed_at,
    normalize_records,
)
from _knowledge_social_slack_route_types import ConversationTarget
from _knowledge_social_slack_zip import index_archive, read_regular_archive
from knowledge_social_import import canonical_json
from knowledge_social_store import SocialStoreError, validate_opaque

MAX_FUTURE_EXPORT_SECONDS = 5 * 60


def _timestamp(value: str) -> str:
    observed_at = canonical_observed_at(value, "export observation time")
    parsed = datetime.fromisoformat(observed_at.replace("Z", "+00:00"))
    latest = datetime.fromtimestamp(
        social_now() + MAX_FUTURE_EXPORT_SECONDS, UTC
    )
    if parsed > latest:
        raise SocialStoreError("Slack export observation time is in the future")
    return observed_at


def _coverage(
    targets: dict[str, ConversationTarget],
    present: dict[str, int],
    observed_at: str,
) -> list[dict[str, Any]]:
    rows = [
        {
            "stream": "archive",
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": True,
            "retention_limit": "approved_export_date_range_and_workspace_retention",
            "unavailable_reason": "export_date_range_and_retention_bound_history",
            "status": "partial",
            "observed_at": observed_at,
        }
    ]
    for alias in sorted(targets):
        count = present.get(alias, 0)
        rows.append(
            {
                "stream": f"conversation/{alias}/archive",
                "earliest_at": None,
                "latest_at": None,
                "cursor_exhausted": True,
                "retention_limit": "approved_export_date_range_and_workspace_retention",
                "unavailable_reason": (
                    "export_date_range_and_retention_bound_history"
                    if count
                    else "allowlisted_conversation_has_no_message_files_in_export"
                ),
                "status": "partial" if count else "unavailable",
                "observed_at": observed_at,
            }
        )
    gaps = (
        ("archive_unallowlisted_conversations", "conversation_allowlist_excludes_other_export_content", "partial"),
        ("archive_bookmarks", "channel_bookmarks_are_not_documented_export_members", "unavailable"),
        ("archive_files", "json_exports_contain_file_links_not_file_binaries", "partial"),
        ("archive_edits_deletions", "edit_and_deletion_records_depend_on_retention_policy", "partial"),
        ("archive_threads", "json_exports_preserve_thread_timestamps_without_separate_thread_order", "partial"),
        ("archive_layouts", "nested_org_and_single_user_export_layouts_are_not_supported", "unavailable"),
        ("archive_rich_message_surfaces", "blocks_attachments_canvases_and_huddles_are_not_normalized", "partial"),
    )
    rows.extend(
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": "approved_export_date_range_and_workspace_retention",
            "unavailable_reason": reason,
            "status": status,
            "observed_at": observed_at,
        }
        for stream, reason, status in gaps
    )
    return rows


def build_slack_archive(request: SlackArchiveRequest) -> ParsedSlackArchive:
    """Build filtered immutable evidence and normalized rows from one JSON ZIP."""
    validate_opaque(request.connection_id, "connection_id")
    if not request.profile.conversations:
        raise SocialStoreError("Slack export requires a non-empty conversation allowlist")
    observed_at = _timestamp(request.exported_at)
    payload = read_regular_archive(request.path, request.max_bytes)
    source_sha256 = hashlib.sha256(payload).hexdigest()
    with index_archive(payload, request.max_bytes, request.max_items) as index:
        selection = select_archive_records(request, index)
        account = selection.account
        records = selection.records
        streams = tuple(
            ["archive"]
            + [
                f"conversation/{alias}/archive"
                for alias in sorted(request.profile.conversations)
            ]
        )
        context = PageContext(
            request.connection_id,
            account,
            "archive",
            streams,
            {
                "media_hydration": "none",
                "slack_export_sha256": source_sha256,
                "slack_export_filtered": True,
            },
        )
        archive = normalize_records(
            records,
            context,
            NormalizationBatch(
                observed_at,
                EXPORT_SOURCE,
                tuple(
                    _coverage(
                        request.profile.conversations, selection.present, observed_at
                    )
                ),
            ),
        )
        evidence_value = {
            "schema": 1,
            "provider": PROVIDER,
            "source": EXPORT_SOURCE,
            "source_sha256": source_sha256,
            "connection_id": request.connection_id,
            "workspace_id": account["workspace_id"],
            "enterprise_id": account["enterprise_id"],
            "account_id": account["id"],
            "token_type": account["token_type"],
            "conversation_binding_sha256": account[
                "conversation_binding_sha256"
            ],
            "selected_member_sha256": {
                name: hashlib.sha256(index.member_bytes(name)).hexdigest()
                for name in sorted(selection.selected_members)
            },
            "records": records,
        }
    reject_slack_credentials(evidence_value)
    evidence = canonical_json(evidence_value).encode("utf-8")
    evidence_sha256 = hashlib.sha256(evidence).hexdigest()
    normalized_items = sum(
        len(archive[key]) for key in ("accounts", "objects", "activities", "media")
    )
    if normalized_items > request.max_items:
        raise SocialStoreError("Slack export exceeds the normalized item budget")
    return ParsedSlackArchive(
        archive,
        evidence,
        source_sha256,
        evidence_sha256,
        streams[1:],
        len(selection.selected_members),
        normalized_items,
    )
