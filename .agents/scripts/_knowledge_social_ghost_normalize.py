#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Ghost public records into provider-neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_ghost import (
    ACCOUNT_AUTH_MODE,
    PROVIDER,
    RETENTION_LIMIT,
    GhostAdapterError,
    instance_id,
    page_data,
)
from _knowledge_social_ghost_http import ACCEPT_VERSION
from knowledge_social_import import reject_credentials

PROVENANCE = "ghost_content_api_v6"
GAPS = (
    ("members", "sensitive_admin_member_records_are_not_enabled"),
    ("newsletters", "mutation_capable_admin_authority_is_not_enabled"),
    ("comments", "no_stable_documented_content_or_integration_read_route"),
    ("account_export", "manual_owner_export_is_not_fixture_validated"),
    ("staff_and_owner_identity", "privileged_admin_identity_is_not_enabled"),
    ("drafts_and_unpublished", "mutation_capable_admin_authority_is_not_enabled"),
    ("deleted_or_purged_content", "not_available_through_current_public_reads"),
    ("provider_retention", "no_publication_specific_retention_guarantee"),
)
OBJECT_TYPES = frozenset({"post", "page", "tag", "author"})


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _required_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value or "\x00" in value:
        raise GhostAdapterError(f"Ghost record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise GhostAdapterError(f"Ghost record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise GhostAdapterError("Ghost page observed_at must be text")
    return value


def _text(record: dict[str, Any]) -> str | None:
    values = [
        value
        for key in (
            "title",
            "plaintext",
            "custom_excerpt",
            "excerpt",
            "name",
            "description",
            "bio",
        )
        if (value := _optional_text(record, key))
    ]
    return "\n\n".join(dict.fromkeys(values)) or None


def _coverage(observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason,
            "status": "unavailable",
            "observed_at": observed_at,
        }
        for stream, reason in GAPS
    ]


def _item_kind(item: dict[str, Any]) -> str:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise GhostAdapterError("Ghost page contains an unsupported item kind")
    return kind


def _occurred_at(item: dict[str, Any]) -> str | None:
    return _optional_text(item, "published_at") or _optional_text(item, "created_at")


def _object_row(
    item: dict[str, Any], context: PageContext, observed_at: str, installation: str
) -> dict[str, Any]:
    kind = _item_kind(item)
    remote_id = _required_text(item, "remote_id")
    published = kind in ("post", "page")
    provider_json = {
        "source": PROVENANCE,
        "instance_id": installation,
        "stream": context.stream,
        "record": item,
    }
    reject_credentials(provider_json)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id") if published else None,
        "text": _text(item),
        "created_at": _occurred_at(item),
        "observed_at": observed_at,
        "evidence_class": "published" if published else "observed",
        "provider_json": provider_json,
    }


def _activity_rows(
    items: list[dict[str, Any]],
    context: PageContext,
    observed_at: str,
    installation: str,
) -> list[dict[str, Any]]:
    if context.stream not in ("posts", "pages"):
        return []
    account_id = _required_text(context.account, "id")
    return [
        {
            "activity_type": f"published_{_item_kind(item)}",
            "remote_id": f"{account_id}_published_{_required_text(item, 'remote_id')}",
            "actor_remote_id": account_id,
            "object_remote_id": _required_text(item, "remote_id"),
            "occurred_at": _occurred_at(item),
            "observed_at": observed_at,
            "state": "active",
            "provider_json": {
                "source": PROVENANCE,
                "instance_id": installation,
                "stream": context.stream,
            },
        }
        for item in items
    ]


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build provider-neutral rows and explicit Ghost trust-boundary gaps."""
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    installation = instance_id(context.account.get("instance_id"))
    items = page_data(payload)
    objects = [_object_row(item, context, observed_at, installation) for item in items]
    policy = dict(context.policy)
    policy.update(
        {
            "ghost_auth_mode": ACCOUNT_AUTH_MODE,
            "ghost_api_version": ACCEPT_VERSION,
            "ghost_instance_id": installation,
            "ghost_transport": "stdlib_urllib_get_only",
            "ghost_redirects": "rejected",
            "ghost_admin_routes": "unauthenticated_site_identity_only",
            "ghost_private_records": "members_comments_and_staff_excluded",
        }
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account.get("id"),
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": context.account.get("id"),
                "handle": context.account.get("site_id"),
                "display_name": context.account.get("name"),
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "instance_id": installation,
                    "provider_account_id": context.account.get("provider_account_id"),
                    "site_version": context.account.get("version"),
                },
            }
        ],
        "objects": objects,
        "activities": _activity_rows(items, context, observed_at, installation),
        "media": [],
        "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
