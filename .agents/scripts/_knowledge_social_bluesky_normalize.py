#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize repository, AppView, sync, and chat evidence without merging authority."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from _knowledge_social_bluesky import (
    PROVIDER,
    RETENTION_LIMIT,
    STREAMS,
    BlueskyAdapterError,
    did,
    page_data,
    service_id,
)
from knowledge_social_import import canonical_json, reject_credentials

GAPS = (
    ("repository_car_export", "binary_car_import_requires_separately_validated_private_export"),
    ("historical_tombstones", "snapshot_queries_do_not_expose_complete_deletion_history"),
    ("blob_bytes", "blob_metadata_only_binary_download_not_enabled"),
    ("pds_migration_history", "current_verified_service_alias_only"),
    ("chat_export", "separate_chat_export_procedure_not_enabled"),
)
ACTIVITY_ONLY_STREAMS = frozenset(
    {"likes", "reposts", "follows", "blocks", "list_items"}
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
    if not isinstance(value, str) or not value:
        raise BlueskyAdapterError("Bluesky page observed_at must be text")
    return value


def _optional_text(item: dict[str, Any], *keys: str) -> str | None:
    for key in keys:
        value = item.get(key)
        if isinstance(value, str) and value and "\x00" not in value:
            return value[:262144]
    return None


def _record_value(item: dict[str, Any]) -> dict[str, Any]:
    value = item.get("value")
    return value if isinstance(value, dict) else item


def _object(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _subject_id(item: dict[str, Any]) -> str | None:
    value = _record_value(item)
    subject = value.get("subject")
    if isinstance(subject, str):
        return subject
    return _optional_text(_object(subject), "uri", "did", "cid")


def _stable_hash(namespace: str, value: Any) -> str:
    return f"bluesky:{namespace}:" + hashlib.sha256(canonical_json(value).encode()).hexdigest()


def _preference_id(item: dict[str, Any]) -> str | None:
    record_type = _optional_text(item, "$type")
    if record_type is None:
        return None
    discriminators = {
        key: item.get(key)
        for key in ("labelerDid", "label", "feed", "tag", "actor", "did")
        if item.get(key) is not None
    }
    return (
        _stable_hash("preference", {"type": record_type, **discriminators})
        if discriminators
        else record_type
    )


def _remote_id(item: dict[str, Any], stream: str) -> str:
    value = _record_value(item)
    if stream == "chat_log":
        remote = _optional_text(item, "rev")
    elif stream == "author_feed":
        remote = _optional_text(_object(item.get("post")), "uri")
    elif stream == "bookmarks":
        remote = _optional_text(_object(item.get("subject")), "uri")
    elif stream == "mutes":
        remote = _optional_text(item, "did")
    elif stream == "labels":
        identity = {
            key: item.get(key) for key in ("src", "uri", "val", "cts", "neg")
        }
        remote = _stable_hash("label", identity)
    elif stream in {"likes", "reposts", "follows", "blocks", "list_items"}:
        remote = _subject_id(item)
    elif stream == "preferences":
        remote = _preference_id(item)
    else:
        remote = _optional_text(
            item, "uri", "cid", "did", "id", "convoId", "messageId"
        )
        remote = remote or _optional_text(
            value, "uri", "cid", "did", "id", "subject"
        )
    if remote:
        return remote
    return _stable_hash(stream, item)


def _text_sources(item: dict[str, Any], stream: str) -> list[dict[str, Any]]:
    value = _record_value(item)
    sources = [value, item]
    if stream == "author_feed":
        post = _object(item.get("post"))
        sources = [_object(post.get("record")), post, *sources]
    elif stream == "bookmarks":
        bookmarked = _object(item.get("item"))
        sources = [_object(bookmarked.get("record")), bookmarked, *sources]
    elif stream == "chat_log":
        sources = [_object(item.get("message")), *sources]
    return sources


def _text(item: dict[str, Any], stream: str) -> str | None:
    parts = [
        text
        for source in _text_sources(item, stream)
        for key in ("displayName", "name", "title", "text", "description")
        if isinstance((text := source.get(key)), str) and text
    ]
    return "\n\n".join(dict.fromkeys(parts))[:262144] or None


def _created_at(item: dict[str, Any], stream: str) -> str | None:
    for source in _text_sources(item, stream):
        created = _optional_text(
            source, "createdAt", "indexedAt", "sentAt", "updatedAt"
        )
        if created:
            return created
    return None


def _activity_remote_id(
    item: dict[str, Any], stream: str, account_did: str, target_id: str
) -> str:
    if stream == "chat_log":
        return _optional_text(item, "rev") or _stable_hash("chat-event", item)
    if stream in {"likes", "reposts", "follows", "blocks", "list_items"}:
        return _optional_text(item, "uri") or _stable_hash(stream, item)
    if stream == "labels":
        return target_id
    return f"{account_did}:{STREAMS[stream].activity_mode}:{target_id}"


def _actor_id(item: dict[str, Any], stream: str, account_did: str) -> str:
    if stream == "chat_log":
        sender = _object(_object(item.get("message")).get("sender"))
        return _optional_text(sender, "did") or account_did
    return account_did


def _deleted(item: dict[str, Any], stream: str) -> bool:
    record_type = _optional_text(item, "$type") or ""
    return bool(
        item.get("deleted")
        or _record_value(item).get("deleted")
        or (stream == "chat_log" and "logDeleteMessage" in record_type)
    )


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


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build canonical rows while retaining each service as explicit provenance."""
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    spec = STREAMS[context.stream]
    account_did = did(context.account.get("id"), "account DID")
    authority_id = service_id(
        context.account.get("pds_id" if spec.authority in ("pds", "sync") else f"{spec.authority}_id")
    )
    objects = []
    activities = []
    media = []
    for item in page_data(payload):
        remote_id = _remote_id(item, context.stream)
        value = _record_value(item)
        deleted = _deleted(item, context.stream)
        provider_json = {
            "authority": spec.authority,
            "service_id": authority_id,
            "stream": context.stream,
            "at_uri": _optional_text(item, "uri") or _optional_text(value, "uri"),
            "cid": _optional_text(item, "cid") or _optional_text(value, "cid"),
            "revision": _optional_text(item, "rev") or _optional_text(value, "rev"),
            "action_at_uri": _optional_text(item, "uri"),
            "target_remote_id": remote_id,
            "tombstone": deleted,
            "record": item,
        }
        reject_credentials(provider_json)
        if context.stream not in ACTIVITY_ONLY_STREAMS:
            objects.append(
                {
                    "object_type": spec.resource_kind,
                    "remote_id": remote_id,
                    "account_remote_id": account_did
                    if context.stream in {"profile", "posts"}
                    else None,
                    "text": _text(item, context.stream),
                    "created_at": _created_at(item, context.stream),
                    "observed_at": observed_at,
                    "evidence_class": "authored"
                    if context.stream in {"profile", "posts"}
                    else "observed",
                    "provider_json": provider_json,
                }
            )
        activities.append(
            {
                "activity_type": spec.activity_mode,
                "remote_id": _activity_remote_id(
                    item, context.stream, account_did, remote_id
                ),
                "actor_remote_id": _actor_id(item, context.stream, account_did),
                "object_remote_id": remote_id,
                "occurred_at": _created_at(item, context.stream),
                "observed_at": observed_at,
                "state": "deleted" if deleted else "active",
                "provider_json": {
                    "authority": spec.authority,
                    "service_id": authority_id,
                    "stream": context.stream,
                },
            }
        )
        if context.stream == "blobs":
            media.append(
                {
                    "remote_id": remote_id,
                    "object_remote_id": remote_id,
                    "content_sha256": None,
                    "mime_type": None,
                    "byte_size": None,
                    "blob_ref": remote_id,
                    "hydration_state": "metadata_only",
                }
            )
    policy = dict(context.policy)
    policy.update(
        {
            "bluesky_identity": "stable_did",
            "bluesky_authority": spec.authority,
            "bluesky_service_id": authority_id,
            "bluesky_transport": "stdlib_urllib_get_only_xrpc_queries",
            "bluesky_procedures": "unreachable",
        }
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": account_did,
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": account_did,
                "handle": context.account.get("handle"),
                "display_name": context.account.get("name"),
                "observed_at": observed_at,
                "provider_json": {
                    "identity": "did",
                    "pds_id": context.account.get("pds_id"),
                    "appview_id": context.account.get("appview_id"),
                    "chat_id": context.account.get("chat_id"),
                },
            }
        ],
        "objects": objects,
        "activities": activities,
        "media": media,
        "coverage": _coverage(observed_at),
    }
    reject_credentials(archive)
    return archive
