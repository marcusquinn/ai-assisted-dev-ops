#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only subprocess for Google Business Profile APIs."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import sys
import time
from dataclasses import dataclass
from datetime import UTC, date, datetime, timedelta
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
STABLE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
API_BASES = frozenset(
    {
        "https://www.googleapis.com/oauth2/v3",
        "https://mybusinessaccountmanagement.googleapis.com/v1",
        "https://mybusinessbusinessinformation.googleapis.com/v1",
        "https://mybusiness.googleapis.com/v4",
        "https://mybusinessverifications.googleapis.com/v1",
        "https://businessprofileperformance.googleapis.com/v1",
    }
)
READ_STREAMS = frozenset(
    {
        "location_profile",
        "attributes",
        "media",
        "local_posts",
        "reviews",
        "verification_state",
        "performance",
        "search_keywords",
    }
)
RATE_LIMIT_REASONS = frozenset(
    {"dailyLimitExceeded", "quotaExceeded", "rateLimitExceeded", "userRateLimitExceeded"}
)
UrlOpen = Callable[..., Any]


class ProviderError(RuntimeError):
    """Raised for a privacy-safe local provider failure."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded HTTP result without provider error-body disclosure."""

    status: int
    payload: dict[str, Any]
    retry_after: int | None = None


@dataclass(frozen=True)
class Identity:
    """Expected hierarchy loaded only inside the guarded process."""

    google_subject: str
    account_id: str
    organization_id: str | None
    location_id: str


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise ProviderError("Google Business Profile OAuth profile name is invalid")
    return f"GOOGLE_BUSINESS_PROFILE_{profile.upper()}"


def _env(prefix: str, suffix: str, *, optional: bool = False) -> str | None:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value and optional:
        return None
    if not value or "\x00" in value or len(value.encode("utf-8")) > 16 * 1024:
        raise ProviderError("Google Business Profile OAuth profile is incomplete")
    return value


def _stable_id(value: Any, field: str, *, optional: bool = False) -> str | None:
    if value is None and optional:
        return None
    if not isinstance(value, str) or STABLE_ID.fullmatch(value) is None:
        raise ProviderError(f"Google Business Profile {field} is invalid")
    return value


def _profile(profile: str) -> tuple[str, Identity]:
    prefix = _profile_prefix(profile)
    token = _env(prefix, "ACCESS_TOKEN")
    subject = _env(prefix, "GOOGLE_SUBJECT")
    account_id = _stable_id(_env(prefix, "ACCOUNT_ID"), "account ID")
    organization_id = _stable_id(
        _env(prefix, "ORGANIZATION_ID", optional=True),
        "organization ID",
        optional=True,
    )
    location_id = _stable_id(_env(prefix, "LOCATION_ID"), "location ID")
    if token is None or subject is None or account_id is None or location_id is None:
        raise ProviderError("Google Business Profile OAuth profile is incomplete")
    return token, Identity(subject, account_id, organization_id, location_id)


def _http_exports() -> UrlOpen:
    if not callable(Request) or not callable(urlopen) or not callable(urlencode):
        raise ProviderError("Python urllib HTTP exports are unavailable")
    return urlopen


def _observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _decode_response(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ProviderError("Google Business Profile response exceeds the safety limit")
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProviderError("Google Business Profile returned no valid JSON") from error
    if not isinstance(value, dict):
        raise ProviderError("Google Business Profile response root must be an object")
    return value


def _retry_epoch(value: str | None) -> int | None:
    try:
        seconds = float(value) if value is not None else -1
    except (TypeError, ValueError):
        return None
    if not math.isfinite(seconds) or seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def _terminal_status(error: HTTPError) -> int:
    if error.code != 403:
        return error.code
    try:
        body = _decode_response(error.read(MAX_RESPONSE_BYTES + 1))
    except (OSError, ProviderError):
        return error.code
    envelope = body.get("error")
    details = envelope.get("errors") if isinstance(envelope, dict) else None
    reasons = {
        entry.get("reason")
        for entry in details or []
        if isinstance(entry, dict) and isinstance(entry.get("reason"), str)
    }
    return 429 if reasons.intersection(RATE_LIMIT_REASONS) else error.code


def _api(
    token: str,
    opener: UrlOpen,
    base: str,
    path: str,
    params: dict[str, Any] | None = None,
) -> ApiResult:
    if base not in API_BASES or not path.startswith("/") or ".." in path:
        raise ProviderError("Google Business Profile API route is not allowlisted")
    filtered = {
        key: value for key, value in (params or {}).items() if value is not None
    }
    query = urlencode(filtered, doseq=True)
    url = f"{base}{path}{'?' + query if query else ''}"
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "User-Agent": "aidevops-google-business-profile-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise ProviderError("Google Business Profile HTTP response is invalid")
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise ProviderError("Google Business Profile HTTP status is invalid")
            return ApiResult(status, _decode_response(payload))
    except HTTPError as error:
        return ApiResult(
            _terminal_status(error), {}, _retry_epoch(error.headers.get("Retry-After"))
        )
    except (TimeoutError, URLError, OSError) as error:
        raise ProviderError("Google Business Profile read provider request failed") from error


def _terminal(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": _observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _resource_name(payload: dict[str, Any], expected: str) -> dict[str, Any]:
    if payload.get("name") != expected:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    return payload


def _identity(
    api: Callable[[str, str, dict[str, Any] | None], ApiResult],
    expected_location_id: str,
    identity: Identity,
) -> dict[str, Any]:
    if expected_location_id != identity.location_id:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    user = api("https://www.googleapis.com/oauth2/v3", "/userinfo", None)
    account = api(
        "https://mybusinessaccountmanagement.googleapis.com/v1",
        f"/accounts/{identity.account_id}",
        None,
    )
    if user.status != 200:
        return _terminal(user)
    if account.status != 200:
        return _terminal(account)
    if user.payload.get("sub") != identity.google_subject:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    _resource_name(account.payload, f"accounts/{identity.account_id}")
    if identity.organization_id is not None:
        organization = api(
            "https://mybusinessaccountmanagement.googleapis.com/v1",
            f"/accounts/{identity.organization_id}",
            None,
        )
        if organization.status != 200:
            return _terminal(organization)
        _resource_name(organization.payload, f"accounts/{identity.organization_id}")
    location = api(
        "https://mybusinessbusinessinformation.googleapis.com/v1",
        f"/locations/{identity.location_id}",
        {"readMask": "name,title,metadata"},
    )
    if location.status != 200:
        return _terminal(location)
    _resource_name(location.payload, f"locations/{identity.location_id}")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": {
            "id": identity.location_id,
            "business_account_id": identity.account_id,
            "organization_id": identity.organization_id,
            "title": location.payload.get("title"),
            "google_identity_verified": True,
        },
    }


def _page_token(cursor: Any) -> str | None:
    if cursor is None:
        return None
    if not isinstance(cursor, dict) or set(cursor) != {"page_token"}:
        raise ProviderError("Google Business Profile page cursor is invalid")
    token = cursor.get("page_token")
    if not isinstance(token, str) or not token or len(token) > 2048:
        raise ProviderError("Google Business Profile page cursor is invalid")
    return token


def _copy(payload: dict[str, Any], keys: tuple[str, ...]) -> dict[str, Any]:
    return {key: payload[key] for key in keys if payload.get(key) is not None}


def _derived_name(stream: str, item: dict[str, Any]) -> str:
    """Build stable projection identity without metric values or observation time."""
    candidates: tuple[Any, ...]
    if stream == "performance":
        candidates = (item.get("dailyMetric"), item.get("dailySubEntityType"))
    elif stream == "search_keywords":
        candidates = (item.get("searchKeyword"),)
    elif stream == "attributes":
        candidates = (item.get("attributeId"),)
    else:
        candidates = (item.get("name"), item.get("reviewId"), item.get("mediaKey"))
    identity = [candidate for candidate in candidates if candidate is not None]
    if not identity:
        raise ProviderError(
            f"Google Business Profile {stream} record has no stable identity"
        )
    digest = hashlib.sha256(
        json.dumps(identity, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()[:24]
    return f"{stream}-{digest}"


def _records(stream: str, payload: dict[str, Any], location_id: str) -> list[dict[str, Any]]:
    if stream == "location_profile":
        profile = payload.get("profile") if isinstance(payload.get("profile"), dict) else {}
        text = "\n\n".join(
            value
            for value in (payload.get("title"), profile.get("description"))
            if isinstance(value, str) and value
        ) or None
        return [{
            "kind": "location_profile",
            "remote_id": location_id,
            "text": text,
            "provider_json": _copy(payload, (
                "storeCode", "phoneNumbers", "categories", "storefrontAddress",
                "websiteUri", "regularHours", "specialHours", "serviceArea", "labels",
                "latlng", "openInfo", "metadata", "relationshipData", "moreHours",
                "serviceItems", "profile",
            )),
        }]
    key_map = {
        "attributes": "attributes",
        "media": "mediaItems",
        "local_posts": "localPosts",
        "reviews": "reviews",
        "performance": "multiDailyMetricTimeSeries",
        "search_keywords": "searchKeywordsCounts",
    }
    if stream == "verification_state":
        return [{
            "kind": "verification_state",
            "remote_id": f"{location_id}-voice-of-merchant",
            "provider_json": _copy(payload, ("hasVoiceOfMerchant", "hasBusinessAuthority")),
        }]
    items = payload.get(key_map[stream], [])
    if not isinstance(items, list) or any(not isinstance(item, dict) for item in items):
        raise ProviderError("Google Business Profile list response is invalid")
    records: list[dict[str, Any]] = []
    for position, item in enumerate(items):
        name = item.get("name") or item.get("reviewId") or item.get("mediaKey")
        if not isinstance(name, str) or not name:
            name = _derived_name(stream, item)
        if stream == "reviews":
            comment = item.get("comment") if isinstance(item.get("comment"), str) else None
            records.append({
                "kind": "review",
                "remote_id": name,
                "text": comment,
                "created_at": item.get("createTime"),
                "updated_at": item.get("updateTime"),
                "protected": True,
                "provider_json": _copy(item, ("starRating", "createTime", "updateTime")),
            })
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
        elif stream == "local_posts":
            summary = item.get("summary") if isinstance(item.get("summary"), str) else None
            records.append({
                "kind": "local_post", "remote_id": name, "text": summary,
                "created_at": item.get("createTime"), "updated_at": item.get("updateTime"),
                "provider_json": _copy(item, ("topicType", "callToAction", "event", "offer", "product", "state")),
            })
        elif stream == "media":
            records.append({
                "kind": "media", "remote_id": name,
                "created_at": item.get("createTime"),
                "provider_json": _copy(item, ("mediaFormat", "locationAssociation", "googleUrl", "thumbnailUrl", "dimensions", "insights")),
            })
        elif stream == "attributes":
            attribute_id = item.get("attributeId")
            records.append({
                "kind": "attribute", "remote_id": attribute_id or name,
                "provider_json": _copy(item, ("attributeId", "valueType", "values", "repeatedEnumValue")),
            })
        elif stream == "performance":
            records.append({
                "kind": "performance_metric", "remote_id": name,
                "provider_json": _copy(item, ("dailyMetric", "dailySubEntityType", "timeSeries")),
            })
        elif stream == "search_keywords":
            keyword = item.get("searchKeyword")
            keyword_text = keyword if isinstance(keyword, str) else None
            records.append({
                "kind": "search_keyword", "remote_id": name,
                "text": keyword_text,
                "provider_json": _copy(item, ("insightsValue",)),
            })
        else:
            raise ProviderError("Google Business Profile read stream is unsupported")
        if position >= 999:
            raise ProviderError("Google Business Profile page exceeds the item safety limit")
    return records


def _month(value: date) -> dict[str, int]:
    return {"year": value.year, "month": value.month}


def _route(
    api: Callable[[str, str, dict[str, Any] | None], ApiResult],
    request: dict[str, Any],
    identity: Identity,
) -> dict[str, Any]:
    stream = request.get("stream")
    limit = request.get("limit")
    if stream not in READ_STREAMS:
        raise ProviderError("Google Business Profile read stream is unsupported")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise ProviderError("Google Business Profile read limit must be between 1 and 100")
    if request.get("location_id") != identity.location_id or request.get("business_account_id") != identity.account_id or request.get("organization_id") != identity.organization_id:
        raise ProviderError(
            "selected Google identity or Business Profile hierarchy does not match the configured connection"
        )
    if request.get("stop_at") is not None:
        raise ProviderError("Google Business Profile snapshot watermark must be empty")
    token = _page_token(request.get("cursor"))
    common = {"pageSize": limit, "pageToken": token}
    account_location = f"accounts/{identity.account_id}/locations/{identity.location_id}"
    if stream == "location_profile":
        base = "https://mybusinessbusinessinformation.googleapis.com/v1"
        path = f"/locations/{identity.location_id}"
        params = {"readMask": "name,title,storeCode,phoneNumbers,categories,storefrontAddress,websiteUri,regularHours,specialHours,serviceArea,labels,latlng,openInfo,metadata,profile,relationshipData,moreHours,serviceItems"}
    elif stream == "attributes":
        base = "https://mybusinessbusinessinformation.googleapis.com/v1"
        path = f"/locations/{identity.location_id}/attributes"
        params = common
    elif stream == "media":
        base = "https://mybusiness.googleapis.com/v4"
        path = f"/{account_location}/media"
        params = common
    elif stream == "local_posts":
        base = "https://mybusiness.googleapis.com/v4"
        path = f"/{account_location}/localPosts"
        params = common
    elif stream == "reviews":
        base = "https://mybusiness.googleapis.com/v4"
        path = f"/{account_location}/reviews"
        params = common
    elif stream == "verification_state":
        base = "https://mybusinessverifications.googleapis.com/v1"
        path = f"/locations/{identity.location_id}/VoiceOfMerchantState"
        params = None
    elif stream == "performance":
        end = date.today() - timedelta(days=1)
        start = end - timedelta(days=89)
        base = "https://businessprofileperformance.googleapis.com/v1"
        path = f"/locations/{identity.location_id}:fetchMultiDailyMetricsTimeSeries"
        params = {
            "dailyMetrics": ["BUSINESS_IMPRESSIONS_DESKTOP_MAPS", "BUSINESS_IMPRESSIONS_MOBILE_MAPS", "BUSINESS_IMPRESSIONS_DESKTOP_SEARCH", "BUSINESS_IMPRESSIONS_MOBILE_SEARCH", "WEBSITE_CLICKS", "CALL_CLICKS", "BUSINESS_DIRECTION_REQUESTS"],
            "dailyRange.startDate.year": start.year,
            "dailyRange.startDate.month": start.month,
            "dailyRange.startDate.day": start.day,
            "dailyRange.endDate.year": end.year,
            "dailyRange.endDate.month": end.month,
            "dailyRange.endDate.day": end.day,
        }
    else:
        end = date.today().replace(day=1) - timedelta(days=1)
        start = (end.replace(day=1) - timedelta(days=335)).replace(day=1)
        base = "https://businessprofileperformance.googleapis.com/v1"
        path = f"/locations/{identity.location_id}/searchkeywords/impressions/monthly"
        params = {
            "monthlyRange.startMonth.year": _month(start)["year"],
            "monthlyRange.startMonth.month": _month(start)["month"],
            "monthlyRange.endMonth.year": _month(end)["year"],
            "monthlyRange.endMonth.month": _month(end)["month"],
            **common,
        }
    result = api(base, path, params)
    if result.status != 200:
        return _terminal(result)
    next_token = result.payload.get("nextPageToken")
    if next_token is not None and (not isinstance(next_token, str) or not next_token):
        raise ProviderError("Google Business Profile next page token is invalid")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": _records(stream, result.payload, identity.location_id),
        "meta": {
            "next_cursor": {"page_token": next_token} if next_token else None,
            "complete": next_token is None,
            "snapshot": True,
        },
    }


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise ProviderError("Google Business Profile request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProviderError("Google Business Profile request is not valid JSON") from error
    if not isinstance(request, dict):
        raise ProviderError("Google Business Profile request root must be an object")
    return request


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise ProviderError("Google Business Profile response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = _request()
        token, identity = _profile(args.profile)
        opener = _http_exports()
        api = lambda base, path, params=None: _api(token, opener, base, path, params)
        action = request.get("action")
        if action == "identity" and set(request) == {"action", "account_id"}:
            expected = _stable_id(request.get("account_id"), "location ID")
            if expected is None:
                raise ProviderError("Google Business Profile location ID is invalid")
            payload = _identity(api, expected, identity)
        elif action == "page" and set(request) == {
            "action", "stream", "location_id", "business_account_id",
            "organization_id", "cursor", "stop_at", "limit",
        }:
            fence = _identity(api, identity.location_id, identity)
            payload = fence if fence.get("status") != 200 else _route(api, request, identity)
        else:
            raise ProviderError("Google Business Profile read action is unsupported")
        _emit(payload)
        return 0
    except ProviderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Google Business Profile read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
