#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize root-bound Notion observations into neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_notion import PROVIDER, RETENTION_LIMIT, page_data
from _knowledge_social_notion_identity import NotionAdapterError, notion_id
from knowledge_social_import import reject_credentials

PROVENANCE = "notion_public_api_2026_03_11_explicit_roots"
FIXED_COVERAGE = (
    {
        "stream": "resolved_comments",
        "status": "unavailable",
        "reason": "public_api_lists_only_open_unresolved_comments",
    },
    {
        "stream": "file_bytes",
        "status": "unavailable",
        "reason": "signed_and_external_file_targets_are_never_fetched",
    },
    {
        "stream": "external_embeds",
        "status": "unavailable",
        "reason": "external_embed_and_bookmark_targets_are_never_fetched",
    },
    {
        "stream": "workspace_search",
        "status": "unavailable",
        "reason": "title_search_is_not_an_authorized_or_exhaustive_inventory_route",
    },
    {
        "stream": "notion_site_metadata",
        "status": "unavailable",
        "reason": "public_site_url_is_not_an_account_api_or_authority_grant",
    },
    {
        "stream": "workspace_export",
        "status": "unavailable",
        "reason": "owner_or_enterprise_admin_export_is_a_separate_import_route",
    },
)


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value or "\x00" in value:
        raise NotionAdapterError("Notion page observed_at must be text")
    return value


def _optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise NotionAdapterError(f"Notion normalized {field} must be text")
    return value


def _remote_id(kind: str, value: Any) -> str:
    return f"notion_{kind}_{notion_id(value, f'{kind} ID').replace('-', '')}"


def _object(record: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    kind = record.get("kind")
    if kind not in {"page", "block", "database", "comment"}:
        raise NotionAdapterError("Notion normalized object kind is invalid")
    text = _optional_text(record.get("text"), "object text")
    provider_json = {
        "record": record,
        "root_page_ids": context.account.get("root_page_ids"),
        "source": PROVENANCE,
        "workspace_id": context.account.get("workspace_id"),
    }
    reject_credentials(provider_json)
    return {
        "account_remote_id": notion_id(
            context.account.get("workspace_id"), "workspace ID"
        ),
        "created_at": _optional_text(record.get("created_at"), "creation time"),
        "evidence_class": "authorized_integration_content",
        "object_type": kind,
        "observed_at": observed_at,
        "provider_json": provider_json,
        "remote_id": _remote_id(kind, record.get("id")),
        "text": text,
    }


def _coverage(observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "cursor_exhausted": False,
            "earliest_at": None,
            "latest_at": None,
            "observed_at": observed_at,
            "retention_limit": RETENTION_LIMIT,
            "status": gap["status"],
            "stream": gap["stream"],
            "unavailable_reason": gap["reason"],
        }
        for gap in FIXED_COVERAGE
    ]


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    workspace = notion_id(context.account.get("workspace_id"), "workspace ID")
    if notion_id(context.account.get("id"), "account ID") != workspace:
        raise NotionAdapterError("Notion workspace identity binding is invalid")
    records = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "notion_api_version": "2026-03-11",
            "notion_authority": "integration_workspace_plus_explicit_root_page_ids",
            "notion_comments": "unresolved_only_when_profile_capability_is_enabled",
            "notion_files": "metadata_only_no_remote_fetch",
            "notion_pagination": "opaque_cursor_with_durable_bounded_queue",
            "notion_search": "disabled",
        }
    )
    archive = {
        "accounts": [
            {
                "display_name": _optional_text(
                    context.account.get("workspace_name"), "workspace name"
                ),
                "handle": None,
                "observed_at": observed_at,
                "provider_json": {
                    "bot_id": context.account.get("bot_id"),
                    "owner_type": context.account.get("owner_type"),
                    "root_page_ids": context.account.get("root_page_ids"),
                    "source": PROVENANCE,
                },
                "remote_id": workspace,
            }
        ],
        "activities": [],
        "connection_id": context.connection_id,
        "coverage": _coverage(observed_at),
        "enabled_streams": list(context.enabled_streams),
        "exported_at": observed_at,
        "media": [],
        "objects": [_object(record, context, observed_at) for record in records],
        "policy": policy,
        "provider": PROVIDER,
        "remote_account_id": workspace,
    }
    reject_credentials(archive)
    return archive
