#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bluesky stream policy, DID identity, and service-fenced cursors."""

from __future__ import annotations

import base64
import json
import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials

PROVIDER = "bluesky"
CURSOR_PREFIX = "bluesky-v1:"
RETENTION_LIMIT = "current_repository_and_authorized_service_visibility"
DID_PATTERN = re.compile(r"^did:(?:plc|web):[A-Za-z0-9._:%-]{3,512}$")
SERVICE_ID_PATTERN = re.compile(r"^[0-9a-f]{24}$")


class BlueskyAdapterError(RuntimeError):
    """Bluesky fixture, validation, or normalization failure."""


class BlueskyProviderUnavailableError(BlueskyAdapterError):
    """Live Bluesky provider boundary is unavailable."""


ADAPTER_ERROR = BlueskyAdapterError
PROVIDER_UNAVAILABLE_ERROR = BlueskyProviderUnavailableError


@dataclass(frozen=True)
class StreamSpec:
    """Authority, route, normalization, and budget policy for one stream."""

    resource_kind: str
    activity_mode: str
    pagination: str
    incremental: bool
    retention_limit: str | None
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 4
    authority: str = "pds"
    endpoint: str = "com.atproto.repo.listRecords"
    collection: str | None = None


def _repo(kind: str, activity: str, collection: str) -> StreamSpec:
    return StreamSpec(kind, activity, "cursor", False, RETENTION_LIMIT, collection=collection)


def _query(kind: str, activity: str, authority: str, endpoint: str) -> StreamSpec:
    return StreamSpec(
        kind,
        activity,
        "cursor",
        False,
        RETENTION_LIMIT,
        authority=authority,
        endpoint=endpoint,
    )


STREAMS = {
    "profile": _repo("profile", "authored_profile", "app.bsky.actor.profile"),
    "posts": _repo("post", "authored_post", "app.bsky.feed.post"),
    "reposts": _repo("post", "repost", "app.bsky.feed.repost"),
    "likes": _repo("post", "like", "app.bsky.feed.like"),
    "follows": _repo("profile", "follow", "app.bsky.graph.follow"),
    "blocks": _repo("profile", "block", "app.bsky.graph.block"),
    "lists": _repo("list", "owned_list", "app.bsky.graph.list"),
    "list_items": _repo("profile", "list_membership", "app.bsky.graph.listitem"),
    "feed_generators": _repo("feed", "owned_feed", "app.bsky.feed.generator"),
    "starter_packs": _repo("starter_pack", "owned_starter_pack", "app.bsky.graph.starterpack"),
    "labeler_services": _repo("labeler_service", "owned_labeler_service", "app.bsky.labeler.service"),
    "repo_status": _query("repository", "repository_status", "sync", "com.atproto.sync.getRepoStatus"),
    "blobs": _query("blob", "repository_blob", "sync", "com.atproto.sync.listBlobs"),
    "author_feed": _query("post", "appview_author_feed", "appview", "app.bsky.feed.getAuthorFeed"),
    "notifications": _query("notification", "notification", "appview", "app.bsky.notification.listNotifications"),
    "preferences": _query("preference", "account_preference", "appview", "app.bsky.actor.getPreferences"),
    "bookmarks": _query("post", "bookmark", "appview", "app.bsky.bookmark.getBookmarks"),
    "mutes": _query("profile", "mute", "appview", "app.bsky.graph.getMutes"),
    "appview_lists": _query("list", "subscribed_list", "appview", "app.bsky.graph.getLists"),
    "appview_starter_packs": _query("starter_pack", "joined_starter_pack", "appview", "app.bsky.graph.getActorStarterPacks"),
    "labels": _query("label", "moderation_label", "appview", "com.atproto.label.queryLabels"),
    "chat_conversations": _query("conversation", "chat_participation", "chat", "chat.bsky.convo.listConvos"),
    "chat_log": _query("chat_event", "chat_event", "chat", "chat.bsky.convo.getLog"),
    "repository_export": StreamSpec(
        "repository_export",
        "repository_export",
        "none",
        False,
        RETENTION_LIMIT,
        "unavailable",
        "binary_car_import_requires_separately_validated_private_export",
        authority="pds",
        endpoint="unavailable",
    ),
}


def did(value: Any, field: str = "DID") -> str:
    if not isinstance(value, str) or DID_PATTERN.fullmatch(value) is None:
        raise BlueskyAdapterError(f"Bluesky {field} is invalid")
    return value


def service_id(value: Any, field: str = "service identity") -> str:
    if not isinstance(value, str) or SERVICE_ID_PATTERN.fullmatch(value) is None:
        raise BlueskyAdapterError(f"Bluesky {field} is invalid")
    return value


def text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or not value or "\x00" in value or len(value.encode()) > 4096:
        raise BlueskyAdapterError(f"Bluesky {field} is invalid")
    return value


@dataclass(frozen=True)
class PageRequest:
    stream: str
    account_id: str
    handle: str
    service_id: str
    authority: str
    endpoint: str
    collection: str | None
    cursor: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "handle": self.handle,
            "service_id": self.service_id,
            "authority": self.authority,
            "endpoint": self.endpoint,
            "collection": self.collection,
            "cursor": self.cursor,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = set(PageRequest("", "", "", "", "", "", None, None, 1).payload())


def _encode_cursor(stream: str, account_did: str, service: str, remote: str) -> str:
    payload = canonical_json(
        {"stream": stream, "did": account_did, "service": service, "remote": remote}
    ).encode()
    encoded = base64.urlsafe_b64encode(payload).decode("ascii").rstrip("=")
    return f"{CURSOR_PREFIX}{encoded}"


def _decode_cursor(cursor: str) -> dict[str, str]:
    if not cursor.startswith(CURSOR_PREFIX):
        raise BlueskyAdapterError("stored Bluesky cursor has an unsupported version")
    try:
        value = cursor.removeprefix(CURSOR_PREFIX)
        payload = json.loads(base64.urlsafe_b64decode(value + "=" * (-len(value) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise BlueskyAdapterError("stored Bluesky cursor is invalid") from error
    if not isinstance(payload, dict) or set(payload) != {"stream", "did", "service", "remote"}:
        raise BlueskyAdapterError("stored Bluesky cursor has an invalid shape")
    reject_credentials(payload)
    return {key: text(payload[key], f"cursor {key}") or "" for key in payload}


def _stream_service(account: dict[str, Any], authority: str) -> str:
    field = {"pds": "pds_id", "sync": "pds_id", "appview": "appview_id", "chat": "chat_id"}[authority]
    return service_id(account.get(field), field)


def page_request(stream: str, account: dict[str, Any], state: CursorState, limit: int) -> PageRequest:
    spec = STREAMS.get(stream)
    if spec is None:
        raise BlueskyAdapterError("Bluesky stream is unsupported")
    account_did = did(account.get("id"), "selected account DID")
    selected_service = _stream_service(account, spec.authority)
    remote_cursor = None
    if state.cursor:
        stored = _decode_cursor(state.cursor)
        if stored["stream"] != stream or stored["did"] != account_did:
            raise BlueskyAdapterError("stored Bluesky cursor belongs to another stream or DID")
        if stored["service"] == selected_service:
            remote_cursor = stored["remote"]
    return PageRequest(
        stream,
        account_did,
        text(account.get("handle"), "handle") or "",
        selected_service,
        spec.authority,
        spec.endpoint,
        spec.collection,
        remote_cursor,
        limit,
    )


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise BlueskyAdapterError("Bluesky read request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise BlueskyAdapterError("Bluesky stream is unsupported")
    spec = STREAMS[stream]
    if (payload.get("authority"), payload.get("endpoint"), payload.get("collection")) != (
        spec.authority,
        spec.endpoint,
        spec.collection,
    ):
        raise BlueskyAdapterError("Bluesky read route is not allowlisted")
    limit = payload.get("limit")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise BlueskyAdapterError("Bluesky page size is invalid")
    cursor = text(payload.get("cursor"), "page cursor", optional=True)
    return PageRequest(
        stream,
        did(payload.get("account_id"), "account DID"),
        text(payload.get("handle"), "handle") or "",
        service_id(payload.get("service_id")),
        spec.authority,
        spec.endpoint,
        spec.collection,
        cursor,
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise BlueskyAdapterError("Bluesky response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise BlueskyAdapterError("Bluesky page data must be an array")
    return data


def page_checkpoint(payload: dict[str, Any], state: CursorState, request: PageRequest) -> tuple[PageCheckpoint, bool]:
    del state
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise BlueskyAdapterError("Bluesky page metadata must be an object")
    reject_credentials(meta)
    if meta.get("stream") != request.stream or did(meta.get("did")) != request.account_id:
        raise BlueskyAdapterError("Bluesky page provenance is invalid")
    if service_id(meta.get("service_id")) != request.service_id:
        raise BlueskyAdapterError("Bluesky service changed during collection")
    complete = meta.get("complete")
    if not isinstance(complete, bool):
        raise BlueskyAdapterError("Bluesky page completion metadata is invalid")
    remote = text(meta.get("next_cursor"), "next cursor", optional=True)
    if complete != (remote is None):
        raise BlueskyAdapterError("Bluesky cursor and completion state disagree")
    next_cursor = None if remote is None else _encode_cursor(request.stream, request.account_id, request.service_id, remote)
    watermark = text(meta.get("watermark"), "watermark", optional=True)
    return PageCheckpoint(next_cursor, watermark), complete
