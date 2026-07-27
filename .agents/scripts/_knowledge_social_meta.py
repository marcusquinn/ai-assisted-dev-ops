#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Per-product Meta stream manifests and resumable Graph cursors."""

from __future__ import annotations

import base64
import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError

GRAPH_API_VERSION = "v25.0"
THREADS_API_VERSION = "v1.0"
CURSOR_PREFIX = "meta-graph-v1"
MAX_CURSOR_BYTES = 2048
ACCOUNT_ID = re.compile(r"^[0-9]{1,32}$")
GRAPH_ID = re.compile(r"^[0-9]{1,32}(?:_[0-9]{1,32})?$")
RETENTION_LIMIT = "delete_when_no_longer_needed_or_authorized_under_meta_platform_terms"


class MetaAdapterError(SocialStoreError):
    """Raised when guarded Meta collection cannot continue safely."""


class MetaProviderUnavailableError(MetaAdapterError):
    """Raised when the bounded Meta OAuth child cannot complete a read."""


ADAPTER_ERROR = MetaAdapterError
PROVIDER_UNAVAILABLE_ERROR = MetaProviderUnavailableError


@dataclass(frozen=True)
class CapabilityGap:
    """One explicit non-live product capability."""

    stream: str
    status: str
    reason: str


@dataclass(frozen=True)
class StreamSpec:
    """One allowlisted product edge and its normalized meaning."""

    edge: str
    fields: tuple[str, ...]
    resource_kind: str
    activity_type: str
    evidence_class: str
    required_scopes: tuple[str, ...]
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = None
    unavailable_reason: str | None = None
    cost_units: int = 2


@dataclass(frozen=True)
class ProductSpec:
    """Identity, authorization, and capability boundary for one Meta product."""

    product: str
    api_base: str
    api_version: str
    paging_hosts: tuple[str, ...]
    identity_fields: tuple[str, ...]
    identity_path: str
    account_gate: str
    authorization_scopes: tuple[str, ...]
    streams: dict[str, StreamSpec]
    gaps: tuple[CapabilityGap, ...]


def _capability_gaps(
    unavailable: dict[str, str], export_reason: str
) -> tuple[CapabilityGap, ...]:
    """Build explicit gap records from compact immutable declarations."""
    gaps = tuple(
        CapabilityGap(stream, "unavailable", reason)
        for stream, reason in unavailable.items()
    )
    return gaps + (CapabilityGap("account_export", "export", export_reason),)


FACEBOOK_STREAMS = {
    "posts": StreamSpec(
        "posts",
        (
            "id",
            "created_time",
            "message",
            "parent_id",
            "permalink_url",
            "status_type",
            "updated_time",
        ),
        "post",
        "content_author",
        "authored",
        ("pages_read_engagement",),
    )
}

INSTAGRAM_STREAMS = {
    "media": StreamSpec(
        "media",
        (
            "id",
            "caption",
            "comments_count",
            "like_count",
            "media_product_type",
            "media_type",
            "media_url",
            "permalink",
            "thumbnail_url",
            "timestamp",
            "username",
        ),
        "media",
        "content_author",
        "authored",
        ("instagram_basic", "pages_read_engagement"),
    )
}

THREADS_FIELDS = (
    "id",
    "media_type",
    "media_url",
    "permalink",
    "text",
    "timestamp",
    "username",
)
THREADS_STREAMS = {
    "posts": StreamSpec(
        "threads",
        THREADS_FIELDS,
        "post",
        "content_author",
        "authored",
        ("threads_basic",),
    ),
    "replies": StreamSpec(
        "replies",
        THREADS_FIELDS,
        "reply",
        "content_author",
        "authored",
        ("threads_basic", "threads_read_replies"),
    ),
    "mentions": StreamSpec(
        "mentions",
        THREADS_FIELDS,
        "mention",
        "account_mentioned",
        "observed",
        ("threads_basic", "threads_manage_mentions"),
    ),
}

PRODUCTS = {
    "facebook": ProductSpec(
        "facebook",
        f"https://graph.facebook.com/{GRAPH_API_VERSION}",
        GRAPH_API_VERSION,
        ("graph.facebook.com",),
        ("id", "name", "category"),
        "account",
        "managed_page_with_page_access_token_and_app_review",
        ("pages_read_engagement", "pages_show_list"),
        FACEBOOK_STREAMS,
        _capability_gaps(
            {
                "curated_activity": "facebook_page_api_does_not_expose_personal_saved_or_curated_activity",
                "comments": "facebook_comments_require_a_separately_bounded_per_post_traversal",
                "account_relationships": "facebook_page_api_does_not_expose_personal_follow_relationships",
                "messages": "facebook_messaging_api_is_not_a_general_account_history_route",
            },
            "facebook_export_has_no_validated_private_schema_or_importer",
        ),
    ),
    "instagram": ProductSpec(
        "instagram",
        f"https://graph.facebook.com/{GRAPH_API_VERSION}",
        GRAPH_API_VERSION,
        ("graph.facebook.com",),
        ("id", "username", "name", "followers_count", "follows_count", "media_count"),
        "account",
        "page_connected_instagram_business_or_creator_account_with_app_review",
        ("instagram_basic", "pages_read_engagement", "pages_show_list"),
        INSTAGRAM_STREAMS,
        _capability_gaps(
            {
                "comments": "instagram_comments_require_a_separately_bounded_per_media_traversal",
                "mentions": "instagram_mentions_require_separate_permission_and_edge_validation",
                "relationships": "instagram_graph_api_does_not_expose_follower_or_following_lists",
                "saved_collections": "instagram_graph_api_does_not_expose_personal_saved_collections",
            },
            "instagram_export_has_no_validated_private_schema_or_importer",
        ),
    ),
    "threads": ProductSpec(
        "threads",
        f"https://graph.threads.com/{THREADS_API_VERSION}",
        THREADS_API_VERSION,
        ("graph.threads.com", "graph.threads.net"),
        ("id", "username", "name", "is_verified"),
        "me",
        "threads_app_user_token_with_product_specific_reviewed_permissions",
        (
            "threads_basic",
            "threads_manage_mentions",
            "threads_read_replies",
        ),
        THREADS_STREAMS,
        _capability_gaps(
            {
                "interactions": "threads_account_like_and_repost_history_has_no_verified_list_edge",
                "relationships": "threads_follower_and_following_lists_have_no_verified_account_edge",
                "messages": "threads_api_has_no_general_private_message_history_route",
                "custom_feeds": "threads_custom_feed_membership_has_no_verified_account_edge",
            },
            "threads_export_has_no_validated_private_schema_or_importer",
        ),
    ),
}


@dataclass(frozen=True)
class PageRequest:
    """One exact, bounded Graph API list request."""

    product: str
    stream: str
    account_id: str
    edge: str
    fields: tuple[str, ...]
    after: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "product": self.product,
            "stream": self.stream,
            "account_id": self.account_id,
            "edge": self.edge,
            "fields": ",".join(self.fields),
            "after": self.after,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


def product_spec(product: Any) -> ProductSpec:
    """Return one product manifest without accepting aliases."""
    if not isinstance(product, str) or product not in PRODUCTS:
        raise MetaAdapterError("Meta product is unsupported")
    return PRODUCTS[product]


def graph_id(value: Any, field: str) -> str:
    """Validate a stable numeric or documented composite Graph identifier."""
    if not isinstance(value, str) or GRAPH_ID.fullmatch(value) is None:
        raise MetaAdapterError(f"Meta {field} must be a stable Graph ID")
    return value


def account_id(value: Any, field: str) -> str:
    """Validate a stable numeric product account identifier."""
    if not isinstance(value, str) or ACCOUNT_ID.fullmatch(value) is None:
        raise MetaAdapterError(f"Meta {field} must be a stable numeric account ID")
    return value


def provider_cursor(value: Any) -> str:
    """Validate an opaque provider cursor before use or storage."""
    if not isinstance(value, str) or not value or "\x00" in value:
        raise MetaAdapterError("Meta page cursor is invalid")
    if len(value.encode("utf-8")) > MAX_CURSOR_BYTES:
        raise MetaAdapterError("Meta page cursor exceeds the safety limit")
    return value


def _stored_cursor(product: str, cursor: str) -> str:
    encoded = base64.urlsafe_b64encode(provider_cursor(cursor).encode("utf-8"))
    return f"{CURSOR_PREFIX}:{product}:{encoded.decode('ascii').rstrip('=')}"


def _decoded_cursor(product: str, cursor: str) -> str:
    prefix = f"{CURSOR_PREFIX}:{product}:"
    if not cursor.startswith(prefix):
        raise MetaAdapterError("stored Meta cursor has an unsupported product or version")
    encoded = cursor.removeprefix(prefix)
    if not encoded or not encoded.isascii():
        raise MetaAdapterError("stored Meta cursor is invalid")
    try:
        decoded = base64.b64decode(
            encoded + "=" * (-len(encoded) % 4), altchars=b"-_", validate=True
        ).decode("utf-8")
    except (UnicodeDecodeError, ValueError) as error:
        raise MetaAdapterError("stored Meta cursor is invalid") from error
    return provider_cursor(decoded)


def page_request(
    product: str,
    stream: str,
    account: dict[str, Any],
    state: CursorState,
    limit: int,
) -> PageRequest:
    """Build one product-scoped request from durable per-stream state."""
    spec = product_spec(product)
    if stream not in spec.streams:
        raise MetaAdapterError("Meta stream is unsupported for the selected product")
    stream_spec = spec.streams[stream]
    remote_account_id = account_id(account.get("id"), "account ID")
    after = _decoded_cursor(product, state.cursor) if state.cursor else None
    return PageRequest(
        product,
        stream,
        remote_account_id,
        stream_spec.edge,
        stream_spec.fields,
        after,
        limit,
    )


def response_status(payload: dict[str, Any]) -> int:
    """Return a validated HTTP-like status from a Meta response."""
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise MetaAdapterError("Meta response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Return a validated array of allowlisted Meta records."""
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise MetaAdapterError("Meta page data must be an array of objects")
    reject_credentials(data)
    return data


def page_checkpoint(
    product: str,
    payload: dict[str, Any],
    state: CursorState,
    request: PageRequest,
) -> tuple[PageCheckpoint, bool]:
    """Calculate the next independent Graph cursor for one product stream."""
    del state
    meta = payload.get("meta")
    if not isinstance(meta, dict):
        raise MetaAdapterError("Meta page metadata must be an object")
    reject_credentials(meta)
    if meta.get("product") != product or meta.get("stream") != request.stream:
        raise MetaAdapterError("Meta page provenance does not match the request")
    complete = meta.get("complete")
    next_cursor = meta.get("next_cursor")
    if not isinstance(complete, bool):
        raise MetaAdapterError("Meta page completion metadata is invalid")
    if next_cursor is not None:
        next_cursor = provider_cursor(next_cursor)
    if complete == (next_cursor is not None):
        raise MetaAdapterError(
            "complete Meta pages cannot carry a cursor and partial pages require one"
        )
    cursor = _stored_cursor(product, next_cursor) if next_cursor is not None else None
    return PageCheckpoint(cursor, None), complete


class MetaProductModule:
    """Dynamic provider-policy adapter consumed by the shared OAuth collector."""

    ADAPTER_ERROR = MetaAdapterError
    PROVIDER_UNAVAILABLE_ERROR = MetaProviderUnavailableError

    def __init__(self, product: str) -> None:
        spec = product_spec(product)
        self.product = product
        self.PROVIDER = product
        self.STREAMS = spec.streams

    def page_request(
        self,
        stream: str,
        account: dict[str, Any],
        state: CursorState,
        limit: int,
    ) -> PageRequest:
        return page_request(self.product, stream, account, state, limit)

    def page_checkpoint(
        self,
        payload: dict[str, Any],
        state: CursorState,
        request: PageRequest,
    ) -> tuple[PageCheckpoint, bool]:
        return page_checkpoint(self.product, payload, state, request)

    def response_status(self, payload: dict[str, Any]) -> int:
        return response_status(payload)
