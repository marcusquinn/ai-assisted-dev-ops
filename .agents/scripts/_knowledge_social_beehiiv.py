#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""beehiiv publication identity, post policy, and durable page checkpoints."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any

from _knowledge_social_collect import CursorState, PageCheckpoint
from knowledge_social_import import canonical_json, reject_credentials
from knowledge_social_store import SocialStoreError

PROVIDER = "beehiiv"
CURSOR_PREFIX = "beehiiv-v2-page:"
RETENTION_LIMIT = "provider_retention_offset_page_100_and_deletion_boundary"
MAX_PAGE_ITEMS = 100
MAX_PAGE_NUMBER = 100
MAX_TEXT_BYTES = 2 * 1024 * 1024
PUBLICATION = re.compile(r"^pub_[A-Za-z0-9_-]{1,123}$")
POST = re.compile(r"^post_[A-Za-z0-9_-]{1,123}$")


class BeehiivAdapterError(SocialStoreError):
    """Raised when guarded beehiiv collection cannot continue safely."""


class BeehiivProviderUnavailableError(BeehiivAdapterError):
    """Raised when the bounded beehiiv HTTP child cannot complete a read."""


class BeehiivProviderError(RuntimeError):
    """Raised for a privacy-safe local beehiiv provider failure."""


ADAPTER_ERROR = BeehiivAdapterError
PROVIDER_UNAVAILABLE_ERROR = BeehiivProviderUnavailableError


def publication_id(value: Any) -> str:
    """Validate one stable, prefixed beehiiv publication identity."""
    if not isinstance(value, str) or PUBLICATION.fullmatch(value) is None:
        raise BeehiivAdapterError("beehiiv publication ID is invalid")
    return value


def post_id(value: Any) -> str:
    """Validate one stable, prefixed beehiiv post identity."""
    if not isinstance(value, str) or POST.fullmatch(value) is None:
        raise BeehiivAdapterError("beehiiv post ID is invalid")
    return value


def _text(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str):
        raise BeehiivAdapterError(f"beehiiv {field} is invalid")
    if not value and not optional:
        raise BeehiivAdapterError(f"beehiiv {field} is invalid")
    if "\x00" in value or len(value.encode()) > MAX_TEXT_BYTES:
        raise BeehiivAdapterError(f"beehiiv {field} is invalid")
    return value


@dataclass(frozen=True)
class StreamSpec:
    """One intentionally narrow beehiiv stream contract."""

    resource_kind: str
    activity_mode: str
    pagination: str = "offset_page_v2"
    incremental: bool = False
    retention_limit: str | None = RETENTION_LIMIT
    coverage_status: str | None = "partial"
    unavailable_reason: str | None = "offset_page_100_and_provider_retention_boundary"
    cost_units: int = 2


STREAMS = {"posts": StreamSpec("post", "selected_publication")}


@dataclass(frozen=True)
class PageRequest:
    """A selected-publication post page with an evidence-stable request key."""

    stream: str
    account_id: str
    page: int
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "page": self.page,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())


PAGE_REQUEST_KEYS = frozenset(PageRequest.__dataclass_fields__) | {"action"}


def _decode_cursor(value: str) -> int:
    if not value.startswith(CURSOR_PREFIX):
        raise BeehiivAdapterError("stored beehiiv cursor has an unsupported version")
    page = value.removeprefix(CURSOR_PREFIX)
    if not page.isdigit() or not 1 <= int(page) <= MAX_PAGE_NUMBER:
        raise BeehiivAdapterError("stored beehiiv cursor is invalid")
    return int(page)


def _encode_cursor(page: int) -> str:
    if not 1 <= page <= MAX_PAGE_NUMBER:
        raise BeehiivAdapterError("next beehiiv page exceeds the supported API boundary")
    return f"{CURSOR_PREFIX}{page}"


def page_request(
    stream: str, account: dict[str, Any], state: CursorState, limit: int
) -> PageRequest:
    """Build the next bounded snapshot page for the selected publication."""
    if stream not in STREAMS:
        raise BeehiivAdapterError("beehiiv stream is unsupported")
    page = _decode_cursor(state.cursor) if state.cursor else 1
    return PageRequest(stream, publication_id(account.get("id")), page, limit)


def parse_page_request(payload: dict[str, Any]) -> PageRequest:
    """Reject every provider request outside the exact post-page shape."""
    if set(payload) != PAGE_REQUEST_KEYS or payload.get("action") != "page":
        raise BeehiivAdapterError("beehiiv request has an invalid action shape")
    stream = payload.get("stream")
    if not isinstance(stream, str) or stream not in STREAMS:
        raise BeehiivAdapterError("beehiiv stream is unsupported")
    page = payload.get("page")
    limit = payload.get("limit")
    if isinstance(page, bool) or not isinstance(page, int) or not 1 <= page <= MAX_PAGE_NUMBER:
        raise BeehiivAdapterError("beehiiv page number is invalid")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= MAX_PAGE_ITEMS:
        raise BeehiivAdapterError("beehiiv page size is invalid")
    return PageRequest(stream, publication_id(payload.get("account_id")), page, limit)


def response_status(payload: dict[str, Any]) -> int:
    status = payload.get("status", 200)
    if isinstance(status, bool) or not isinstance(status, int):
        raise BeehiivAdapterError("beehiiv response status must be an integer")
    return status


def page_data(payload: dict[str, Any]) -> list[dict[str, Any]]:
    data = payload.get("data", [])
    if not isinstance(data, list) or any(not isinstance(item, dict) for item in data):
        raise BeehiivAdapterError("beehiiv page data must be an array")
    return data


def _non_negative_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise BeehiivAdapterError(f"beehiiv {field} is invalid")
    return value


@dataclass(frozen=True)
class PageMetadata:
    """Validated offset totals and raw or normalized item count."""

    page: int
    total_pages: int
    total_results: int
    item_count: int


def validate_page_metadata(
    metadata: PageMetadata,
    request: PageRequest,
    *,
    exact_items: bool,
) -> None:
    """Reject contradictory offset metadata before a page can advance state."""
    if metadata.page != request.page or metadata.page < 1:
        raise BeehiivAdapterError("beehiiv response page does not match the request")
    expected_pages = (metadata.total_results + request.limit - 1) // request.limit
    if metadata.total_pages != expected_pages:
        raise BeehiivAdapterError("beehiiv pagination totals are inconsistent")
    if metadata.total_pages == 0:
        if metadata.page != 1 or metadata.item_count != 0:
            raise BeehiivAdapterError("beehiiv empty pagination metadata is inconsistent")
        return
    if metadata.page > metadata.total_pages:
        raise BeehiivAdapterError("beehiiv response page exceeds total pages")
    remaining = metadata.total_results - ((metadata.page - 1) * request.limit)
    expected_items = min(request.limit, remaining)
    if metadata.item_count > expected_items or (
        exact_items and metadata.item_count != expected_items
    ):
        raise BeehiivAdapterError("beehiiv page items contradict pagination totals")


def page_checkpoint(
    payload: dict[str, Any], state: CursorState, request: PageRequest
) -> tuple[PageCheckpoint, bool]:
    """Validate page provenance before advancing the offset checkpoint."""
    meta = payload.get("meta")
    expected_keys = {"stream", "publication_id", "page", "total_pages", "total_results"}
    if not isinstance(meta, dict) or set(meta) != expected_keys:
        raise BeehiivAdapterError("beehiiv page provenance is invalid")
    reject_credentials(meta)
    if meta.get("stream") != request.stream:
        raise BeehiivAdapterError("beehiiv page stream does not match the request")
    if publication_id(meta.get("publication_id")) != request.account_id:
        raise BeehiivAdapterError("beehiiv page belongs to another publication")
    page = _non_negative_int(meta.get("page"), "response page")
    total_pages = _non_negative_int(meta.get("total_pages"), "total pages")
    total_results = _non_negative_int(meta.get("total_results"), "total results")
    items = page_data(payload)
    validate_page_metadata(
        PageMetadata(page, total_pages, total_results, len(items)),
        request,
        exact_items=False,
    )
    if total_pages == 0:
        return PageCheckpoint(None, state.watermark), True
    final_page = min(total_pages, MAX_PAGE_NUMBER)
    complete = page >= final_page
    next_cursor = None if complete else _encode_cursor(page + 1)
    return PageCheckpoint(next_cursor, state.watermark), complete


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Bind storage to one explicitly configured, singly visible publication."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise BeehiivAdapterError("beehiiv publication verification returned no identity")
    selected = publication_id(data.get("id"))
    if selected != publication_id(expected_id):
        raise BeehiivAdapterError("selected beehiiv publication does not match expected identity")
    if data.get("scope_verified") is not True:
        raise BeehiivAdapterError("beehiiv publication-scoped authorization is not verified")
    if data.get("ownership_attested") is not True:
        raise BeehiivAdapterError("beehiiv creator ownership is not attested")
    created = data.get("created")
    referral = data.get("referral_program_enabled")
    if isinstance(created, bool) or not isinstance(created, (int, float)) or created < 0:
        raise BeehiivAdapterError("beehiiv publication creation time is invalid")
    if not isinstance(referral, bool):
        raise BeehiivAdapterError("beehiiv publication referral state is invalid")
    return {
        "id": selected,
        "name": _text(data.get("name"), "publication name"),
        "organization_name": _text(data.get("organization_name"), "organization name"),
        "created": created,
        "referral_program_enabled": referral,
        "scope_verified": True,
        "ownership_attested": True,
    }


PROVENANCE = "beehiiv_api_v2"
GAPS = (
    ("draft_and_archived_posts", "default_live_route_collects_confirmed_posts_only"),
    ("premium_post_content", "premium_content_expansion_is_not_requested"),
    ("post_engagement_stats", "subscriber_derived_engagement_metrics_are_excluded"),
    ("subscriptions", "subscriber_pii_requires_separate_justification_and_authorization"),
    ("segments", "segment_membership_can_expose_subscriber_pii"),
    ("post_export", "creator_initiated_dashboard_export_is_not_automated"),
    ("subscriber_export", "sensitive_creator_initiated_export_is_not_imported"),
    ("deletion_history", "api_does_not_prove_complete_deleted_post_history"),
)


@dataclass(frozen=True)
class PageContext:
    connection_id: str
    account: dict[str, Any]
    stream: str
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


def _record_text(record: dict[str, Any], key: str) -> str | None:
    return _text(record.get(key), f"post {key}", optional=True)


def _string_list(record: dict[str, Any], key: str) -> list[str]:
    value = record.get(key, [])
    if (
        not isinstance(value, list)
        or len(value) > 100
        or any(not isinstance(item, str) or not item or "\x00" in item for item in value)
    ):
        raise BeehiivAdapterError(f"beehiiv post {key} is invalid")
    return value


def _coverage(observed: str) -> list[dict[str, Any]]:
    return [
        {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": False,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason,
            "status": "unavailable",
            "observed_at": observed,
        }
        for stream, reason in GAPS
    ]


def _object(record: dict[str, Any], context: PageContext, observed: str) -> dict[str, Any]:
    if record.get("kind") != "post":
        raise BeehiivAdapterError("beehiiv item kind is unsupported")
    remote = post_id(record.get("remote_id"))
    authors = _string_list(record, "authors")
    tags = _string_list(record, "content_tags")
    text_parts = [
        value
        for value in (
            _record_text(record, "title"),
            _record_text(record, "subtitle"),
            _record_text(record, "subject_line"),
            _record_text(record, "preview_text"),
            _record_text(record, "free_web_content"),
            "\n".join(authors) or None,
        )
        if value
    ]
    metadata = {
        key: value
        for key, value in record.items()
        if key not in {"free_web_content", "kind", "remote_id"}
    }
    metadata["content_tags"] = tags
    reject_credentials(metadata)
    return {
        "object_type": "post",
        "remote_id": remote,
        "account_remote_id": context.account.get("id"),
        "text": "\n\n".join(text_parts) or None,
        "created_at": _record_text(record, "publish_date")
        or _record_text(record, "created_at"),
        "observed_at": observed,
        "evidence_class": "authored",
        "provider_json": {
            "source": PROVENANCE,
            "stream": context.stream,
            "record": metadata,
        },
    }


def normalize_page(payload: dict[str, Any], context: PageContext) -> dict[str, Any]:
    """Normalize confirmed post content while excluding subscriber-level data."""
    reject_credentials(payload)
    observed = _text(payload.get("observed_at"), "observed_at")
    if observed is None:
        raise BeehiivAdapterError("beehiiv observed_at is invalid")
    items = page_data(payload)
    policy = dict(context.policy)
    policy.update(
        {
            "beehiiv_identity": "single_visible_publication_plus_expected_id_name_and_organization",
            "beehiiv_pagination": "endpoint_documented_offset_pages_capped_at_100",
            "beehiiv_privacy": "subscriber_pii_segments_stats_and_premium_content_excluded",
            "beehiiv_transport": "fixed_origin_stdlib_urllib_get_only_redirect_rejecting",
        }
    )
    archive = {
        "provider": PROVIDER,
        "connection_id": context.connection_id,
        "remote_account_id": context.account.get("id"),
        "exported_at": observed,
        "enabled_streams": list(context.enabled_streams),
        "policy": policy,
        "accounts": [
            {
                "remote_id": context.account.get("id"),
                "handle": None,
                "display_name": context.account.get("name"),
                "observed_at": observed,
                "provider_json": {
                    "source": PROVENANCE,
                    "organization_name": context.account.get("organization_name"),
                    "created": context.account.get("created"),
                    "referral_program_enabled": context.account.get(
                        "referral_program_enabled"
                    ),
                    "publication_scope_verified": True,
                },
            }
        ],
        "objects": [_object(item, context, observed) for item in items],
        "activities": [],
        "media": [],
        "coverage": _coverage(observed),
    }
    reject_credentials(archive)
    return archive
