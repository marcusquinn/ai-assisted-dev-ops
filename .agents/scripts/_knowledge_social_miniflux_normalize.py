#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Miniflux records into neutral evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_miniflux import PROVIDER, RETENTION_LIMIT, MinifluxAdapterError, page_data
from knowledge_social_import import reject_credentials

PROVENANCE = "miniflux_official_api"
GAPS = (
    ("retained_history", "operator_cleanup_configuration_can_remove_history"),
    ("deleted_subscriptions", "partial_snapshots_do_not_prove_deletion"),
    ("complete_account_archive", "no_verified_complete_account_archive"),
    ("pre_retention_state", "not_recoverable_from_current_api_state"),
)
OBJECT_TYPES = frozenset({"entry", "feed", "category", "tag"})


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
        raise MinifluxAdapterError(f"Miniflux record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise MinifluxAdapterError(f"Miniflux record {key} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise MinifluxAdapterError("Miniflux page observed_at must be text")
    return value


def _coverage(observed_at: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": stream, "earliest_at": None, "latest_at": None,
            "cursor_exhausted": False, "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason, "status": "unavailable",
            "observed_at": observed_at,
        }
        for stream, reason in GAPS
    ]


def _object_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    kind = item.get("kind")
    if not isinstance(kind, str) or kind not in OBJECT_TYPES:
        raise MinifluxAdapterError("Miniflux page contains an unsupported item kind")
    remote_id = _required_text(item, "remote_id")
    text = "\n\n".join(
        value for key in ("title", "body", "author", "category")
        if (value := _optional_text(item, key))
    ) or None
    provider_json = {"source": PROVENANCE, "stream": context.stream, "record": item}
    reject_credentials(provider_json)
    return {
        "object_type": kind, "remote_id": remote_id,
        "account_remote_id": context.account.get("id"), "text": text,
        "created_at": _optional_text(item, "created_at") or _optional_text(item, "published_at"),
        "observed_at": observed_at, "evidence_class": "observed",
        "provider_json": provider_json,
    }


def _activity_row(item: dict[str, Any], context: PageContext, observed_at: str) -> dict[str, Any]:
    selected = _required_text(context.account, "id")
    remote = _required_text(item, "remote_id")
    activity_type = context.stream.removesuffix("s")
    return {
        "activity_type": activity_type,
        "remote_id": f"{selected}_{activity_type}_{remote}",
        "actor_remote_id": selected, "object_remote_id": remote,
        "occurred_at": _optional_text(item, "changed_at") or observed_at,
        "observed_at": observed_at, "state": "active",
        "provider_json": {"source": PROVENANCE, "stream": context.stream},
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update({
        "miniflux_identity": "installation_fingerprint_plus_current_user_id",
        "miniflux_pagination": "ascending_entry_id_with_changed_after_overlap",
        "miniflux_transport": "exact_origin_stdlib_urllib_get_only",
        "miniflux_deletion": "never_inferred_from_partial_snapshots",
    })
    archive = {
        "provider": PROVIDER, "connection_id": context.connection_id,
        "remote_account_id": context.account.get("id"), "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams), "policy": policy,
        "accounts": [{
            "remote_id": context.account.get("id"),
            "handle": context.account.get("username"),
            "display_name": context.account.get("username"),
            "observed_at": observed_at,
            "provider_json": {
                "source": PROVENANCE,
                "installation_id": context.account.get("installation_id"),
                "user_id": context.account.get("user_id"),
            },
        }],
        "objects": [_object_row(item, context, observed_at) for item in items],
        "activities": [_activity_row(item, context, observed_at) for item in items],
        "media": [], "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
