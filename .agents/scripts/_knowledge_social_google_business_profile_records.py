#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted Business Profile response serialization."""

from __future__ import annotations

import hashlib
import json
from typing import Any, Callable


class RecordError(RuntimeError):
    """Raised when a provider response has no safe stable projection."""


PROFILE_FIELDS = tuple(
    (
        "storeCode phoneNumbers categories storefrontAddress websiteUri regularHours "
        "specialHours serviceArea labels latlng openInfo metadata relationshipData "
        "moreHours serviceItems profile"
    ).split()
)


def _copy(payload: dict[str, Any], keys: tuple[str, ...]) -> dict[str, Any]:
    return {key: payload[key] for key in keys if payload.get(key) is not None}


def _name(stream: str, item: dict[str, Any], candidates: tuple[Any, ...]) -> str:
    direct = item.get("name") or item.get("reviewId") or item.get("mediaKey")
    if isinstance(direct, str) and direct:
        return direct
    identity = [candidate for candidate in candidates if candidate is not None]
    if not identity:
        raise RecordError(
            f"Google Business Profile {stream} record has no stable identity"
        )
    digest = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()[:24]
    return f"{stream}-{digest}"


def _profile(payload: dict[str, Any], location_id: str) -> list[dict[str, Any]]:
    profile = payload.get("profile")
    profile = profile if isinstance(profile, dict) else {}
    text = "\n\n".join(
        value
        for value in (payload.get("title"), profile.get("description"))
        if isinstance(value, str) and value
    ) or None
    return [{
        "kind": "location_profile",
        "remote_id": location_id,
        "text": text,
        "provider_json": _copy(payload, PROFILE_FIELDS),
    }]


def _verification(payload: dict[str, Any], location_id: str) -> list[dict[str, Any]]:
    return [{
        "kind": "verification_state",
        "remote_id": f"{location_id}-voice-of-merchant",
        "provider_json": _copy(
            payload, ("hasVoiceOfMerchant", "hasBusinessAuthority")
        ),
    }]


def _attribute(item: dict[str, Any], stream: str) -> list[dict[str, Any]]:
    attribute_id = item.get("attributeId")
    return [{
        "kind": "attribute",
        "remote_id": _name(stream, item, (attribute_id,)),
        "provider_json": _copy(
            item, ("attributeId", "valueType", "values", "repeatedEnumValue")
        ),
    }]


def _media(item: dict[str, Any], stream: str) -> list[dict[str, Any]]:
    return [{
        "kind": "media",
        "remote_id": _name(stream, item, (item.get("mediaKey"),)),
        "created_at": item.get("createTime"),
        "provider_json": _copy(
            item,
            (
                "mediaFormat", "locationAssociation", "googleUrl", "thumbnailUrl",
                "dimensions", "insights",
            ),
        ),
    }]


def _post(item: dict[str, Any], stream: str) -> list[dict[str, Any]]:
    summary = item.get("summary")
    return [{
        "kind": "local_post",
        "remote_id": _name(stream, item, (item.get("name"),)),
        "text": summary if isinstance(summary, str) else None,
        "created_at": item.get("createTime"),
        "updated_at": item.get("updateTime"),
        "provider_json": _copy(
            item, ("topicType", "callToAction", "event", "offer", "product", "state")
        ),
    }]


def _review(item: dict[str, Any], stream: str) -> list[dict[str, Any]]:
    name = _name(stream, item, (item.get("reviewId"),))
    comment = item.get("comment")
    records = [{
        "kind": "review",
        "remote_id": name,
        "text": comment if isinstance(comment, str) else None,
        "created_at": item.get("createTime"),
        "updated_at": item.get("updateTime"),
        "protected": True,
        "provider_json": _copy(item, ("starRating", "createTime", "updateTime")),
    }]
    reply = item.get("reviewReply")
    if isinstance(reply, dict) and isinstance(reply.get("comment"), str):
        records.append({
            "kind": "owner_reply",
            "remote_id": f"{name}-owner-reply",
            "text": reply["comment"],
            "updated_at": reply.get("updateTime"),
            "protected": True,
            "provider_json": {"review_id": name},
        })
    return records


def _performance(item: dict[str, Any], stream: str) -> list[dict[str, Any]]:
    identity = (item.get("dailyMetric"), item.get("dailySubEntityType"))
    return [{
        "kind": "performance_metric",
        "remote_id": _name(stream, item, identity),
        "provider_json": _copy(
            item, ("dailyMetric", "dailySubEntityType", "timeSeries")
        ),
    }]


def _keyword(item: dict[str, Any], stream: str) -> list[dict[str, Any]]:
    keyword = item.get("searchKeyword")
    return [{
        "kind": "search_keyword",
        "remote_id": _name(stream, item, (keyword,)),
        "text": keyword if isinstance(keyword, str) else None,
        "provider_json": _copy(item, ("insightsValue",)),
    }]


LIST_KEYS = {
    "attributes": "attributes",
    "media": "mediaItems",
    "local_posts": "localPosts",
    "reviews": "reviews",
    "performance": "multiDailyMetricTimeSeries",
    "search_keywords": "searchKeywordsCounts",
}
SERIALIZERS: dict[str, Callable[[dict[str, Any], str], list[dict[str, Any]]]] = {
    "attributes": _attribute,
    "media": _media,
    "local_posts": _post,
    "reviews": _review,
    "performance": _performance,
    "search_keywords": _keyword,
}


def serialize_records(
    stream: str, payload: dict[str, Any], location_id: str
) -> list[dict[str, Any]]:
    """Serialize one API response through a stream-specific field allowlist."""
    if stream == "location_profile":
        return _profile(payload, location_id)
    if stream == "verification_state":
        return _verification(payload, location_id)
    key = LIST_KEYS.get(stream)
    serializer = SERIALIZERS.get(stream)
    if key is None or serializer is None:
        raise RecordError("Google Business Profile read stream is unsupported")
    items = payload.get(key, [])
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        raise RecordError("Google Business Profile list response is invalid")
    if len(items) > 1000:
        raise RecordError("Google Business Profile page exceeds the item safety limit")
    return [record for item in items for record in serializer(item, stream)]
