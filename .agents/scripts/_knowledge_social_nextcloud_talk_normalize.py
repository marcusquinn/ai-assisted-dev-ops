#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize allowlisted Nextcloud Talk records into canonical social evidence."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from _knowledge_social_nextcloud_talk import (
    PROVIDER,
    RETENTION_LIMIT,
    NextcloudTalkAdapterError,
    instance_id,
    page_data,
)
from knowledge_social_import import reject_credentials

PROVENANCE = "nextcloud_talk_official_ocs"
GAPS = (
    ("history_before_retention", "server_retention_membership_or_expiration_boundary"),
    ("deleted_before_observation", "not_recoverable_through_current_ocs_history"),
    ("encrypted_or_unreadable", "content_not_returned_to_selected_account"),
    ("reaction_actor_history", "message_pages_expose_counts_not_complete_actor_history"),
    ("poll_details", "poll_objects_require_separate_capability_and_object_reads"),
    ("call_recording_content", "call_system_summaries_only"),
    ("attachment_bytes", "message_linked_metadata_only_until_webdav_identity_is_verified"),
    ("webhook_recovery", "webhooks_are_optional_freshness_not_history_authority"),
)


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


@dataclass(frozen=True)
class ActivityContext:
    page: PageContext
    observed_at: str
    installation: str


def _required_text(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value or "\x00" in value:
        raise NextcloudTalkAdapterError(f"Nextcloud Talk record requires {field}")
    return value


def _optional_text(value: Any, field: str) -> str | None:
    if value is not None and (not isinstance(value, str) or "\x00" in value):
        raise NextcloudTalkAdapterError(f"Nextcloud Talk record {field} must be text")
    return value


def _observed_at(payload: dict[str, Any]) -> str:
    return _required_text(payload.get("observed_at"), "observed_at")


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


def _text(item: dict[str, Any]) -> str | None:
    values = [
        text
        for key in ("name", "text", "system_message")
        if (text := _optional_text(item.get(key), key))
    ]
    return "\n\n".join(values) or None


def _object(
    item: dict[str, Any], context: PageContext, observed_at: str, installation: str
) -> dict[str, Any]:
    kind = _required_text(item.get("kind"), "kind")
    if kind not in {"installation_capability", "conversation", "participant", "message"}:
        raise NextcloudTalkAdapterError("Nextcloud Talk item kind is unsupported")
    remote_id = _required_text(item.get("remote_id"), "remote_id")
    provider_json = {
        "source": PROVENANCE,
        "instance_id": installation,
        "stream": context.stream,
        "record": item,
    }
    reject_credentials(provider_json)
    authored = kind == "message" and item.get("actor_id") == context.account.get("id")
    return {
        "object_type": kind,
        "remote_id": remote_id,
        "account_remote_id": context.account.get("id") if authored else None,
        "text": _text(item),
        "created_at": _optional_text(item.get("created_at"), "created_at"),
        "observed_at": observed_at,
        "evidence_class": "authored" if authored else "observed",
        "provider_json": provider_json,
    }


def _base_activity(
    activity_type: str,
    suffix: str,
    item: dict[str, Any],
    context: ActivityContext,
) -> dict[str, Any]:
    remote_id = _required_text(item.get("remote_id"), "remote_id")
    actor = item.get("actor_id") or context.page.account.get("id")
    return {
        "activity_type": activity_type,
        "remote_id": f"{remote_id}_{suffix}",
        "actor_remote_id": _required_text(actor, "activity actor"),
        "object_remote_id": remote_id,
        "occurred_at": _optional_text(item.get("created_at"), "created_at"),
        "observed_at": context.observed_at,
        "state": "deleted" if item.get("deleted") else "active",
        "provider_json": {
            "source": PROVENANCE,
            "instance_id": context.installation,
            "stream": context.page.stream,
            "room_id": item.get("room_id"),
        },
    }


def _activities(
    item: dict[str, Any], context: ActivityContext
) -> list[dict[str, Any]]:
    kind = _required_text(item.get("kind"), "kind")
    base_type = {
        "installation_capability": "capability_observed",
        "conversation": "room_membership",
        "participant": "participant_membership",
        "message": "message_observed",
    }[kind]
    activities = [_base_activity(base_type, base_type, item, context)]
    if item.get("edited_at"):
        activities.append(
            _base_activity("message_edited", "edited", item, context)
        )
    if item.get("deleted"):
        activities.append(
            _base_activity("message_deleted", "deleted", item, context)
        )
    reactions = item.get("reactions", {})
    if isinstance(reactions, dict):
        for index, (reaction, count) in enumerate(sorted(reactions.items())):
            activity = _base_activity(
                "reaction_summary", f"reaction_{index}", item, context
            )
            activity["provider_json"]["reaction"] = reaction
            activity["provider_json"]["count"] = count
            activities.append(activity)
    return activities


def _media(item: dict[str, Any]) -> list[dict[str, Any]]:
    attachments = item.get("attachments", [])
    if not isinstance(attachments, list):
        raise NextcloudTalkAdapterError("Nextcloud Talk attachments must be an array")
    result: list[dict[str, Any]] = []
    for attachment in attachments:
        if not isinstance(attachment, dict):
            raise NextcloudTalkAdapterError("Nextcloud Talk attachment must be an object")
        result.append(
            {
                "remote_id": _required_text(attachment.get("remote_id"), "attachment ID"),
                "object_remote_id": _required_text(item.get("remote_id"), "message ID"),
                "content_sha256": None,
                "mime_type": _optional_text(attachment.get("mime_type"), "attachment MIME type"),
                "byte_size": attachment.get("byte_size"),
                "blob_ref": None,
                "hydration_state": "metadata",
            }
        )
    return result


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Build canonical rows and explicit capability/authority dispositions."""
    reject_credentials(payload)
    observed_at = _observed_at(payload)
    installation = instance_id(context.account.get("instance_id"))
    activity_context = ActivityContext(context, observed_at, installation)
    items = page_data(payload)
    objects = [_object(item, context, observed_at, installation) for item in items]
    activities = [
        activity
        for item in items
        for activity in _activities(item, activity_context)
    ]
    media = [entry for item in items for entry in _media(item)]
    policy = dict(context.policy)
    policy.update(
        {
            "nextcloud_talk_instance_id": installation,
            "nextcloud_talk_transport": "stdlib_urllib_get_only",
            "nextcloud_talk_room_allowlist": "private_profile",
            "nextcloud_talk_history_authority": "ocs",
            "nextcloud_talk_webhooks": "optional_not_enabled",
            "media_hydration": "metadata",
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
                "handle": None,
                "display_name": context.account.get("name"),
                "observed_at": observed_at,
                "provider_json": {
                    "source": PROVENANCE,
                    "instance_id": installation,
                    "server_version": context.account.get("server_version"),
                    "talk_version": context.account.get("talk_version"),
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
