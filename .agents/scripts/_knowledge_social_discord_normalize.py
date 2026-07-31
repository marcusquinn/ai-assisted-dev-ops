#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize sanitized Discord pages into provider-neutral social records."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from _knowledge_social_discord import (
    PROVIDER,
    DiscordAdapterError,
    page_data,
)
from knowledge_social_import import canonical_json, reject_credentials


@dataclass(frozen=True)
class PageContext:
    """Verified connection policy needed to normalize one Discord page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


@dataclass
class Rows:
    accounts: dict[str, dict[str, Any]]
    objects: dict[tuple[str, str], dict[str, Any]]
    activities: dict[tuple[str, str], dict[str, Any]]
    media: dict[str, dict[str, Any]]


@dataclass(frozen=True)
class AccountDetails:
    handle: str | None = None
    display_name: str | None = None
    provider_json: dict[str, Any] | None = None


@dataclass(frozen=True)
class ObjectDetails:
    account_id: str | None = None
    text: str | None = None
    created_at: str | None = None
    evidence_class: str = "observed"
    provider_json: dict[str, Any] | None = None


@dataclass(frozen=True)
class ActivityDetails:
    object_id: str | None = None
    occurred_at: str | None = None
    state: str = "active"
    provider_json: dict[str, Any] | None = None


def _required(record: dict[str, Any], field: str) -> str:
    value = record.get(field)
    if not isinstance(value, str) or not value:
        raise DiscordAdapterError(f"Discord record requires {field}")
    return value


def _optional(record: dict[str, Any], field: str) -> str | None:
    value = record.get(field)
    if value is not None and not isinstance(value, str):
        raise DiscordAdapterError(f"Discord record {field} must be text")
    return value


def _account(
    remote_id: str,
    observed_at: str,
    details: AccountDetails | None = None,
) -> dict[str, Any]:
    details = details or AccountDetails()
    return {
        "remote_id": remote_id,
        "handle": details.handle,
        "display_name": details.display_name,
        "observed_at": observed_at,
        "provider_json": details.provider_json or {},
    }


def _object(
    kind: str,
    remote_id: str,
    observed_at: str,
    details: ObjectDetails | None = None,
) -> dict[str, Any]:
    details = details or ObjectDetails()
    metadata = details.provider_json or {}
    reject_credentials(metadata)
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": details.account_id,
        "text": details.text,
        "created_at": details.created_at,
        "observed_at": observed_at,
        "evidence_class": details.evidence_class,
        "provider_json": metadata,
    }


def _activity(
    kind: str,
    remote_id: str,
    actor_id: str,
    observed_at: str,
    details: ActivityDetails | None = None,
) -> dict[str, Any]:
    details = details or ActivityDetails()
    return {
        "activity_type": kind,
        "remote_id": remote_id,
        "actor_remote_id": actor_id,
        "object_remote_id": details.object_id,
        "occurred_at": details.occurred_at,
        "observed_at": observed_at,
        "state": details.state,
        "provider_json": details.provider_json or {},
    }


def _user(user: dict[str, Any], observed_at: str, rows: Rows) -> str:
    remote_id = _required(user, "id")
    rows.accounts[remote_id] = _account(
        remote_id,
        observed_at,
        AccountDetails(
            handle=_optional(user, "username"),
            display_name=_optional(user, "global_name"),
            provider_json={"bot": bool(user.get("bot", False))},
        ),
    )
    return remote_id


def _mentions(record: dict[str, Any], observed_at: str, rows: Rows) -> list[str]:
    result = []
    for mention in record.get("mentions", []):
        if not isinstance(mention, dict):
            raise DiscordAdapterError("Discord mention must be an object")
        result.append(_user(mention, observed_at, rows))
    return result


def _attachment(
    attachment: Any, message_id: str, rows: Rows
) -> None:
    if not isinstance(attachment, dict):
        raise DiscordAdapterError("Discord attachment must be an object")
    attachment_id = _required(attachment, "id")
    byte_size = attachment.get("size")
    if isinstance(byte_size, bool) or not isinstance(byte_size, int):
        raise DiscordAdapterError("Discord attachment size must be an integer")
    rows.media[attachment_id] = {
        "remote_id": attachment_id,
        "object_remote_id": message_id,
        "content_sha256": None,
        "mime_type": _optional(attachment, "content_type"),
        "byte_size": byte_size,
        "blob_ref": None,
        "hydration_state": "remote_only",
    }


def _message(record: dict[str, Any], observed_at: str, rows: Rows) -> None:
    remote_id = _required(record, "remote_id")
    author = record.get("author")
    if not isinstance(author, dict):
        raise DiscordAdapterError("Discord message author must be an object")
    author_id = _user(author, observed_at, rows)
    metadata = {
        "channel_id": _required(record, "channel_id"),
        "guild_id": _optional(record, "guild_id"),
        "edited_at": _optional(record, "edited_timestamp"),
        "message_type": record.get("type", 0),
        "mentions": _mentions(record, observed_at, rows),
        "embeds": record.get("embeds", []),
        "reactions": record.get("reactions", []),
        "reference_message_id": _optional(record, "reference_message_id"),
    }
    rows.objects[("message", remote_id)] = _object(
        "message",
        remote_id,
        observed_at,
        ObjectDetails(
            account_id=author_id,
            text=_optional(record, "content"),
            created_at=_optional(record, "timestamp"),
            evidence_class="authored" if author.get("bot") else "observed",
            provider_json=metadata,
        ),
    )
    rows.activities[("message_authored", remote_id)] = _activity(
        "message_authored",
        remote_id,
        author_id,
        observed_at,
        ActivityDetails(
            object_id=remote_id,
            occurred_at=_optional(record, "timestamp"),
        ),
    )
    for attachment in record.get("attachments", []):
        _attachment(attachment, remote_id, rows)


def _metadata(record: dict[str, Any], observed_at: str, rows: Rows) -> None:
    kind = _required(record, "kind")
    remote_id = _required(record, "remote_id")
    if kind == "guild":
        rows.objects[(kind, remote_id)] = _object(
            kind,
            remote_id,
            observed_at,
            ObjectDetails(provider_json={"identity_verified": True}),
        )
        return
    if kind == "member":
        user = record.get("user")
        if not isinstance(user, dict):
            raise DiscordAdapterError("Discord member user must be an object")
        user_id = _user(user, observed_at, rows)
        rows.objects[(kind, f"{record['guild_id']}:{user_id}")] = _object(
            kind,
            f"{record['guild_id']}:{user_id}",
            observed_at,
            ObjectDetails(
                account_id=user_id,
                created_at=_optional(record, "joined_at"),
                provider_json={
                    "guild_id": record["guild_id"],
                    "roles": record.get("roles", []),
                    "nick": record.get("nick"),
                },
            ),
        )
        return
    rows.objects[(kind, remote_id)] = _object(
        kind,
        remote_id,
        observed_at,
        ObjectDetails(
            text=_optional(record, "topic") or _optional(record, "name"),
            provider_json={
                key: value
                for key, value in record.items()
                if key not in {"kind", "remote_id", "name", "topic"}
            },
        ),
    )


def _gateway(
    record: dict[str, Any], context: PageContext, observed_at: str, rows: Rows
) -> None:
    remote_id = _required(record, "remote_id")
    event_name = _required(record, "event_name")
    data = record.get("data")
    if not isinstance(data, dict):
        raise DiscordAdapterError("Discord gateway event data must be an object")
    reject_credentials(data)
    object_id = data.get("id") or data.get("message_id")
    if object_id is not None and not isinstance(object_id, str):
        raise DiscordAdapterError("Discord gateway resource ID must be text")
    rows.objects[("gateway_event", remote_id)] = _object(
        "gateway_event",
        remote_id,
        observed_at,
        ObjectDetails(
            provider_json={
                "event_name": event_name,
                "sequence": record.get("sequence"),
                "data": data,
            }
        ),
    )
    rows.activities[(event_name.lower(), remote_id)] = _activity(
        event_name.lower(),
        remote_id,
        context.account["id"],
        observed_at,
        ActivityDetails(
            object_id=object_id,
            state="deleted" if "DELETE" in event_name else "active",
            provider_json={"observation": True},
        ),
    )


def _export_message(record: dict[str, Any], observed_at: str, rows: Rows) -> None:
    remote_id = _required(record, "remote_id")
    author_id = _required(record, "author_id")
    rows.accounts[author_id] = _account(author_id, observed_at)
    rows.objects[("message", remote_id)] = _object(
        "message",
        remote_id,
        observed_at,
        ObjectDetails(
            account_id=author_id,
            text=_optional(record, "content"),
            created_at=_optional(record, "timestamp"),
            evidence_class="authored",
            provider_json={
                "channel_id": _required(record, "channel_id"),
                "source": "official_account_export",
                "attachment_references": _optional(record, "attachments"),
            },
        ),
    )


def _identity_policy(account: dict[str, Any]) -> dict[str, Any]:
    return {
        key: account[key]
        for key in (
            "application_id",
            "guild_id",
            "channel_ids",
            "thread_ids",
            "dm_channel_ids",
            "message_content_intent",
            "guild_members_intent",
            "export_user_id",
        )
    }


def _coverage(context: PageContext, payload: dict[str, Any], observed_at: str) -> list[dict[str, Any]]:
    reasons = {
        "arbitrary_user_dms": "bot_api_cannot_read_user_dm_history_outside_bot_visible_allowlist",
        "deleted_message_history": "rest_api_does_not_reconstruct_deleted_messages_or_prior_revisions",
        "reaction_users": "reaction_summaries_collected_without_unbounded_user_hydration",
        "attachments": "expiring_cdn_urls_are_transport_data_and_are_not_canonical_identity",
    }
    if not context.account["message_content_intent"]:
        reasons["message_content"] = "message_content_intent_not_enabled_or_approved"
    if not context.account["guild_members_intent"]:
        reasons["guild_members"] = "guild_members_intent_not_enabled_or_approved"
    meta = payload.get("meta", {})
    if isinstance(meta, dict):
        for reason in meta.get("gaps", []):
            if isinstance(reason, str):
                digest = hashlib.sha256(reason.encode()).hexdigest()[:12]
                reasons[f"stream_gap_{digest}"] = reason
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": None,
            "unavailable_reason": reason,
            "status": "unavailable" if stream == "arbitrary_user_dms" else "partial",
            "observed_at": observed_at,
        }
        for stream, reason in reasons.items()
    ]


def _normalize_record(
    record: dict[str, Any], context: PageContext, observed_at: str, rows: Rows
) -> None:
    reject_credentials(record)
    kind = record.get("kind")
    if kind == "message":
        _message(record, observed_at, rows)
    elif kind in {"guild", "channel", "role", "member"}:
        _metadata(record, observed_at, rows)
    elif kind == "gateway_event":
        _gateway(record, context, observed_at, rows)
    elif kind == "export_message":
        _export_message(record, observed_at, rows)
    else:
        raise DiscordAdapterError("Discord page contains an unsupported item kind")


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Validate a successful page and converge API, Gateway, and export evidence."""
    reject_credentials(payload)
    observed_at = payload.get("observed_at")
    if not isinstance(observed_at, str) or not observed_at:
        raise DiscordAdapterError("Discord page observed_at must be text")
    identity = _identity_policy(context.account)
    existing = context.policy.get("discord_identity")
    if existing is not None and existing != identity:
        raise DiscordAdapterError("stored Discord authority does not match verified identity")
    policy = dict(context.policy)
    policy["discord_identity"] = identity
    reject_credentials(policy)
    rows = Rows({}, {}, {}, {})
    rows.accounts[context.account["id"]] = _account(
        context.account["id"],
        observed_at,
        AccountDetails(
            provider_json={
                "application_id": context.account["application_id"],
                "bot": True,
            }
        ),
    )
    for record in page_data(payload):
        _normalize_record(record, context, observed_at, rows)
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account["id"],
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": list(rows.accounts.values()),
        "objects": list(rows.objects.values()),
        "activities": list(rows.activities.values()),
        "media": list(rows.media.values()),
        "coverage": _coverage(context, payload, observed_at),
    }
    reject_credentials(archive)
    canonical_json(archive)
    return archive
