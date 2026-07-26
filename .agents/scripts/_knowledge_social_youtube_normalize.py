#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize sanitized YouTube pages into provider-neutral social records."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass
from typing import Any

from _knowledge_social_youtube import (
    API_RETENTION,
    PROVIDER,
    YouTubeAdapterError,
    page_data,
)
from knowledge_social_import import reject_credentials


@dataclass(frozen=True)
class PageContext:
    """Validated connection policy needed to normalize one YouTube page."""

    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


@dataclass(frozen=True)
class ActivityFields:
    """Validated values used to build one provider-neutral activity."""

    activity_type: str
    remote_id: str
    actor_id: str
    object_id: str | None
    observed_at: str
    occurred_at: str | None
    provider_json: dict[str, Any] | None = None


@dataclass(frozen=True)
class ObjectFields:
    """Validated values used to build one provider-neutral object."""

    object_type: str
    remote_id: str
    account_id: str | None
    text: str | None
    created_at: str | None
    observed_at: str
    evidence_class: str
    provider_json: dict[str, Any]


@dataclass
class NormalizedRows:
    """Mutable normalized row sets for one bounded page."""

    accounts: dict[str, dict[str, Any]]
    objects: dict[tuple[str, str], dict[str, Any]]
    activities: dict[tuple[str, str], dict[str, Any]]


def observation_time(payload: dict[str, Any]) -> str:
    value = payload.get("observed_at")
    if not isinstance(value, str) or not value:
        raise YouTubeAdapterError("YouTube page observed_at must be text")
    return value


def _required_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value:
        raise YouTubeAdapterError(f"YouTube record requires {key}")
    return value


def _optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is not None and not isinstance(value, str):
        raise YouTubeAdapterError(f"YouTube record {key} must be text")
    return value


def _joined_text(record: dict[str, Any], *keys: str) -> str | None:
    values = [_optional_text(record, key) for key in keys]
    return "\n\n".join(value for value in values if value) or None


def _account(
    remote_id: str,
    observed_at: str,
    *,
    handle: str | None = None,
    display_name: str | None = None,
) -> dict[str, Any]:
    return {
        "remote_id": remote_id,
        "handle": handle,
        "display_name": display_name,
        "observed_at": observed_at,
        "provider_json": {},
    }


def _selected_account(account: dict[str, Any], observed_at: str) -> dict[str, Any]:
    remote_id = account.get("id")
    if not isinstance(remote_id, str) or not remote_id:
        raise YouTubeAdapterError("YouTube selected account requires an ID")
    handle = account.get("handle")
    title = account.get("title")
    if handle is not None and not isinstance(handle, str):
        raise YouTubeAdapterError("YouTube selected account handle must be text")
    if title is not None and not isinstance(title, str):
        raise YouTubeAdapterError("YouTube selected account title must be text")
    return _account(remote_id, observed_at, handle=handle, display_name=title)


def _activity(fields: ActivityFields) -> dict[str, Any]:
    return {
        "activity_type": fields.activity_type,
        "remote_id": fields.remote_id,
        "actor_remote_id": fields.actor_id,
        "object_remote_id": fields.object_id,
        "occurred_at": fields.occurred_at,
        "observed_at": fields.observed_at,
        "state": "active",
        "provider_json": fields.provider_json or {},
    }


def _object(fields: ObjectFields) -> dict[str, Any]:
    reject_credentials(fields.provider_json)
    return {
        "object_type": fields.object_type,
        "remote_id": fields.remote_id,
        "account_remote_id": fields.account_id,
        "text": fields.text,
        "created_at": fields.created_at,
        "observed_at": fields.observed_at,
        "evidence_class": fields.evidence_class,
        "provider_json": fields.provider_json,
    }


def _channel_reference(
    record: dict[str, Any], rows: NormalizedRows, observed_at: str
) -> str | None:
    channel_id = _optional_text(record, "channel_id")
    if channel_id is None:
        return None
    rows.accounts[channel_id] = _account(
        channel_id,
        observed_at,
        display_name=_optional_text(record, "channel_title"),
    )
    return channel_id


def _normalize_video(
    record: dict[str, Any],
    context: PageContext,
    observed_at: str,
    rows: NormalizedRows,
) -> None:
    remote_id = _required_text(record, "remote_id")
    channel_id = _channel_reference(record, rows, observed_at)
    if context.stream == "authored_videos":
        channel_id = context.account["id"]
        evidence_class = "authored"
    else:
        evidence_class = "weak_signal"
    video = _object(
        ObjectFields(
            "video",
            remote_id,
            channel_id,
            _joined_text(record, "title", "description"),
            _optional_text(record, "published_at"),
            observed_at,
            evidence_class,
            {
                key: record[key]
                for key in ("playlist_item_id", "position", "privacy_status")
                if record.get(key) is not None
            },
        )
    )
    rows.objects[("video", remote_id)] = video
    activity = _activity(
        ActivityFields(
            context.stream,
            f"{context.account['id']}-{context.stream}-{remote_id}",
            context.account["id"],
            remote_id,
            observed_at,
            video["created_at"],
        )
    )
    rows.activities[(activity["activity_type"], activity["remote_id"])] = activity


def _normalize_playlist(
    record: dict[str, Any],
    context: PageContext,
    observed_at: str,
    rows: NormalizedRows,
) -> None:
    remote_id = _required_text(record, "remote_id")
    playlist = _object(
        ObjectFields(
            "playlist",
            remote_id,
            context.account["id"],
            _joined_text(record, "title", "description"),
            _optional_text(record, "published_at"),
            observed_at,
            "authored",
            {
                key: record[key]
                for key in ("item_count", "privacy_status")
                if record.get(key) is not None
            },
        )
    )
    rows.objects[("playlist", remote_id)] = playlist
    activity = _activity(
        ActivityFields(
            "owned_playlist",
            f"{context.account['id']}-owns-{remote_id}",
            context.account["id"],
            remote_id,
            observed_at,
            playlist["created_at"],
        )
    )
    rows.activities[(activity["activity_type"], activity["remote_id"])] = activity


def _normalize_playlist_item(
    record: dict[str, Any], observed_at: str, rows: NormalizedRows
) -> None:
    membership_id = _required_text(record, "remote_id")
    playlist_id = _required_text(record, "playlist_id")
    video_id = _required_text(record, "video_id")
    video = _object(
        ObjectFields(
            "video",
            video_id,
            None,
            _joined_text(record, "title", "description"),
            None,
            observed_at,
            "observed",
            {
                key: record[key]
                for key in ("privacy_status",)
                if record.get(key) is not None
            },
        )
    )
    rows.objects[("video", video_id)] = video
    membership = _activity(
        ActivityFields(
            "playlist_membership",
            membership_id,
            playlist_id,
            video_id,
            observed_at,
            _optional_text(record, "published_at"),
            {"position": record.get("position")},
        )
    )
    rows.activities[(membership["activity_type"], membership_id)] = membership


def _normalize_subscription(
    record: dict[str, Any],
    context: PageContext,
    observed_at: str,
    rows: NormalizedRows,
) -> None:
    remote_id = _required_text(record, "remote_id")
    subscriber_id = _required_text(record, "subscriber_channel_id")
    target_id = _required_text(record, "subscribed_channel_id")
    if subscriber_id != context.account["id"]:
        raise YouTubeAdapterError("YouTube subscription direction is invalid")
    rows.accounts[target_id] = _account(
        target_id,
        observed_at,
        display_name=_optional_text(record, "title"),
    )
    activity = _activity(
        ActivityFields(
            "subscription",
            remote_id,
            subscriber_id,
            target_id,
            observed_at,
            _optional_text(record, "published_at"),
            {"direction": "selected_account_to_subscribed_channel"},
        )
    )
    rows.activities[(activity["activity_type"], remote_id)] = activity


def _comment_author(
    record: dict[str, Any], observed_at: str, rows: NormalizedRows
) -> str:
    author_id = _optional_text(record, "author_channel_id")
    if author_id is None:
        digest = hashlib.sha256(_required_text(record, "remote_id").encode()).hexdigest()
        author_id = f"unknown_comment_author_{digest}"
    rows.accounts[author_id] = _account(
        author_id,
        observed_at,
        display_name=_optional_text(record, "author_display_name"),
    )
    return author_id


def _normalize_comment(
    record: dict[str, Any],
    context: PageContext,
    observed_at: str,
    rows: NormalizedRows,
) -> None:
    remote_id = _required_text(record, "remote_id")
    parent_id = _optional_text(record, "parent_id")
    author_id = _comment_author(record, observed_at, rows)
    comment = _object(
        ObjectFields(
            "comment",
            remote_id,
            author_id,
            _optional_text(record, "text"),
            _optional_text(record, "published_at"),
            observed_at,
            "authored" if author_id == context.account["id"] else "observed",
            {
                key: record[key]
                for key in ("parent_id", "video_id", "channel_id", "updated_at")
                if record.get(key) is not None
            },
        )
    )
    rows.objects[("comment", remote_id)] = comment
    activity_type = "comment_reply" if parent_id else "comment"
    activity = _activity(
        ActivityFields(
            activity_type,
            remote_id,
            author_id,
            remote_id,
            observed_at,
            comment["created_at"],
            {"parent_id": parent_id} if parent_id else {},
        )
    )
    rows.activities[(activity_type, remote_id)] = activity


def _normalize_activity(
    record: dict[str, Any],
    context: PageContext,
    observed_at: str,
    rows: NormalizedRows,
) -> None:
    remote_id = _required_text(record, "remote_id")
    value = _object(
        ObjectFields(
            "activity",
            remote_id,
            context.account["id"],
            _joined_text(record, "title", "description"),
            _optional_text(record, "published_at"),
            observed_at,
            "observed",
            {
                key: record[key]
                for key in ("activity_type", "subject_id", "subject_kind")
                if record.get(key) is not None
            },
        )
    )
    rows.objects[("activity", remote_id)] = value
    activity = _activity(
        ActivityFields(
            "channel_activity",
            remote_id,
            context.account["id"],
            remote_id,
            observed_at,
            value["created_at"],
            {"provider_activity_type": record.get("activity_type")},
        )
    )
    rows.activities[("channel_activity", remote_id)] = activity


def _gap_coverage(observed_at: str) -> list[dict[str, Any]]:
    gaps = {
        "watch_history": "youtube_data_api_watch_history_not_accessible_export_unverified",
        "watch_later": "youtube_data_api_watch_later_not_accessible_export_unverified",
        "saved_playlists": "youtube_data_api_saved_playlists_not_listable_export_unverified",
        "authored_comments_elsewhere": "youtube_data_api_has_no_complete_account_comment_history",
    }
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": API_RETENTION,
            "unavailable_reason": reason,
            "status": "unavailable",
            "observed_at": observed_at,
        }
        for stream, reason in gaps.items()
    ]


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Validate one successful YouTube page and build provider-neutral rows."""
    reject_credentials(payload)
    observed_at = observation_time(payload)
    rows = NormalizedRows({}, {}, {})
    selected = _selected_account(context.account, observed_at)
    rows.accounts[selected["remote_id"]] = selected
    for item in page_data(payload):
        reject_credentials(item)
        kind = item.get("kind")
        if kind == "video":
            _normalize_video(item, context, observed_at, rows)
        elif kind == "playlist":
            _normalize_playlist(item, context, observed_at, rows)
        elif kind == "playlist_item":
            _normalize_playlist_item(item, observed_at, rows)
        elif kind == "subscription":
            _normalize_subscription(item, context, observed_at, rows)
        elif kind == "comment":
            _normalize_comment(item, context, observed_at, rows)
        elif kind == "activity":
            _normalize_activity(item, context, observed_at, rows)
        else:
            raise YouTubeAdapterError("YouTube page contains an unsupported item kind")
    return {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account["id"],
        "exported_at": observed_at,
        "enabled_streams": list(context.enabled_streams),
        "policy": context.policy,
        "accounts": list(rows.accounts.values()),
        "objects": list(rows.objects.values()),
        "activities": list(rows.activities.values()),
        "media": [],
        "coverage": _gap_coverage(observed_at),
    }
