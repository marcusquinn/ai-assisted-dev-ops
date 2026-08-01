#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted GET routes for current Google Business Profile service families."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, timedelta
from typing import Any, Callable


class RouteError(RuntimeError):
    """Raised when a caller requests a route outside the static read set."""


@dataclass(frozen=True)
class ReadRoute:
    """One fully constructed GET route with bounded query parameters."""

    base: str
    path: str
    params: dict[str, Any] | None


RouteBuilder = Callable[[str, str, str | None, int], ReadRoute]


def _common(token: str | None, limit: int) -> dict[str, Any]:
    return {"pageSize": limit, "pageToken": token}


def _profile(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    del account_id, token, limit
    read_mask = (
        "name,title,storeCode,phoneNumbers,categories,storefrontAddress,websiteUri,"
        "regularHours,specialHours,serviceArea,labels,latlng,openInfo,metadata,"
        "profile,relationshipData,moreHours,serviceItems"
    )
    return ReadRoute(
        "https://mybusinessbusinessinformation.googleapis.com/v1",
        f"/locations/{location_id}",
        {"readMask": read_mask},
    )


def _attributes(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    del account_id, token, limit
    return ReadRoute(
        "https://mybusinessbusinessinformation.googleapis.com/v1",
        f"/locations/{location_id}/attributes",
        None,
    )


def _legacy(
    suffix: str,
    account_id: str,
    location_id: str,
    token: str | None,
    limit: int,
) -> ReadRoute:
    parent = f"accounts/{account_id}/locations/{location_id}"
    return ReadRoute(
        "https://mybusiness.googleapis.com/v4",
        f"/{parent}/{suffix}",
        _common(token, limit),
    )


def _media(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    return _legacy("media", account_id, location_id, token, limit)


def _posts(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    return _legacy("localPosts", account_id, location_id, token, limit)


def _reviews(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    return _legacy("reviews", account_id, location_id, token, limit)


def _verification(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    del account_id, token, limit
    return ReadRoute(
        "https://mybusinessverifications.googleapis.com/v1",
        f"/locations/{location_id}/VoiceOfMerchantState",
        None,
    )


def _performance(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    del account_id, token, limit
    end = date.today() - timedelta(days=1)
    start = end - timedelta(days=89)
    metrics = [
        "BUSINESS_IMPRESSIONS_DESKTOP_MAPS",
        "BUSINESS_IMPRESSIONS_MOBILE_MAPS",
        "BUSINESS_IMPRESSIONS_DESKTOP_SEARCH",
        "BUSINESS_IMPRESSIONS_MOBILE_SEARCH",
        "WEBSITE_CLICKS",
        "CALL_CLICKS",
        "BUSINESS_DIRECTION_REQUESTS",
    ]
    return ReadRoute(
        "https://businessprofileperformance.googleapis.com/v1",
        f"/locations/{location_id}:fetchMultiDailyMetricsTimeSeries",
        {
            "dailyMetrics": metrics,
            "dailyRange.startDate.year": start.year,
            "dailyRange.startDate.month": start.month,
            "dailyRange.startDate.day": start.day,
            "dailyRange.endDate.year": end.year,
            "dailyRange.endDate.month": end.month,
            "dailyRange.endDate.day": end.day,
        },
    )


def _keywords(
    account_id: str, location_id: str, token: str | None, limit: int
) -> ReadRoute:
    del account_id
    end = date.today().replace(day=1) - timedelta(days=1)
    start = (end.replace(day=1) - timedelta(days=335)).replace(day=1)
    params = {
        "monthlyRange.startMonth.year": start.year,
        "monthlyRange.startMonth.month": start.month,
        "monthlyRange.endMonth.year": end.year,
        "monthlyRange.endMonth.month": end.month,
        **_common(token, limit),
    }
    return ReadRoute(
        "https://businessprofileperformance.googleapis.com/v1",
        f"/locations/{location_id}/searchkeywords/impressions/monthly",
        params,
    )


ROUTE_BUILDERS: dict[str, RouteBuilder] = {
    "location_profile": _profile,
    "attributes": _attributes,
    "media": _media,
    "local_posts": _posts,
    "reviews": _reviews,
    "verification_state": _verification,
    "performance": _performance,
    "search_keywords": _keywords,
}
READ_STREAMS = frozenset(ROUTE_BUILDERS)


def build_route(
    stream: str,
    account_id: str,
    location_id: str,
    token: str | None,
    limit: int,
) -> ReadRoute:
    """Build a route only when the stream has a static GET implementation."""
    builder = ROUTE_BUILDERS.get(stream)
    if builder is None:
        raise RouteError("Google Business Profile read stream is unsupported")
    return builder(account_id, location_id, token, limit)
