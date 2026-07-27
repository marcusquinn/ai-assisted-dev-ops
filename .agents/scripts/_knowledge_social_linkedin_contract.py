#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation for the bounded LinkedIn Member Snapshot subprocess."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from urllib.parse import parse_qs, urlsplit

from _knowledge_social_linkedin import MEMBER_ID
from knowledge_social_import import reject_credentials

MAX_TEXT_BYTES = 256 * 1024
MEMBER_URN_PREFIX = "urn:li:person:"


class LinkedInReadProviderError(RuntimeError):
    """Raised for a privacy-safe local LinkedIn provider failure."""


@dataclass(frozen=True)
class ApiResult:
    """One bounded HTTP result without provider error-body disclosure."""

    status: int
    payload: dict[str, Any]
    retry_after: int | None = None
    no_data: bool = False


def observed_at() -> str:
    """Return a stable UTC timestamp for one provider response."""
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    """Reject parent requests outside the allowlisted read contract."""
    if set(request) != expected:
        raise LinkedInReadProviderError(
            "LinkedIn read request has an invalid action shape"
        )


def optional_text(value: Any, field: str) -> str | None:
    """Validate bounded provider text."""
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise LinkedInReadProviderError(f"LinkedIn {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise LinkedInReadProviderError(f"LinkedIn {field} exceeds the safety limit")
    return value


def stable_member_id(value: Any, field: str) -> str:
    """Validate an opaque LinkedIn member ID without accepting a full URN."""
    text = optional_text(value, field)
    if not text or MEMBER_ID.fullmatch(text) is None:
        raise LinkedInReadProviderError(f"LinkedIn {field} is invalid")
    return text


def member_urn_id(value: Any, field: str) -> str:
    """Validate one person URN and return its opaque token."""
    text = optional_text(value, field)
    if not text or not text.startswith(MEMBER_URN_PREFIX):
        raise LinkedInReadProviderError(f"LinkedIn {field} is invalid")
    return stable_member_id(text.removeprefix(MEMBER_URN_PREFIX), field)


def _objects(value: Any, field: str) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise LinkedInReadProviderError(f"LinkedIn {field} must be an array of objects")
    reject_credentials(value)
    return value


def identity_value(payload: dict[str, Any], expected_id: str) -> dict[str, str]:
    """Verify that the token is bound to exactly the configured member."""
    expected = stable_member_id(expected_id, "account ID")
    members: set[str] = set()
    for item in _objects(payload.get("elements", []), "authorization elements"):
        key = item.get("memberComplianceAuthorizationKey")
        if not isinstance(key, dict):
            raise LinkedInReadProviderError(
                "LinkedIn authorization has no member binding"
            )
        members.add(member_urn_id(key.get("member"), "authorization member"))
    if members != {expected}:
        raise LinkedInReadProviderError(
            "selected LinkedIn member does not match the configured connection"
        )
    return {"id": expected}


def terminal_payload(result: ApiResult) -> dict[str, Any]:
    """Build a sanitized terminal response envelope."""
    payload: dict[str, Any] = {"status": result.status, "observed_at": observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _next_start(
    payload: dict[str, Any], domain: str, current_start: int
) -> int:
    paging = payload.get("paging", {})
    if not isinstance(paging, dict):
        raise LinkedInReadProviderError("LinkedIn snapshot paging must be an object")
    links = paging.get("links", [])
    if not isinstance(links, list) or any(not isinstance(link, dict) for link in links):
        raise LinkedInReadProviderError("LinkedIn snapshot links must be an array")
    next_links = [link for link in links if link.get("rel") == "next"]
    if len(next_links) > 1:
        raise LinkedInReadProviderError("LinkedIn snapshot has multiple next links")
    if not next_links:
        start = current_start + 1
        if start > 1_000_000_000:
            raise LinkedInReadProviderError(
                "LinkedIn snapshot next page exceeds the safety limit"
            )
        return start
    href = optional_text(next_links[0].get("href"), "snapshot next link")
    if not href or len(href.encode("utf-8")) > 4096:
        raise LinkedInReadProviderError("LinkedIn snapshot next link is invalid")
    parsed = urlsplit(href)
    if parsed.scheme or parsed.netloc or parsed.fragment:
        raise LinkedInReadProviderError("LinkedIn snapshot next link must be relative")
    if parsed.path != "/rest/memberSnapshotData":
        raise LinkedInReadProviderError("LinkedIn snapshot next endpoint is not allowlisted")
    query = parse_qs(parsed.query, keep_blank_values=True, strict_parsing=True)
    if query.get("q") != ["criteria"] or query.get("domain") != [domain]:
        raise LinkedInReadProviderError("LinkedIn snapshot next query is invalid")
    starts = query.get("start")
    if starts is None or len(starts) != 1 or not starts[0].isascii() or not starts[0].isdigit():
        raise LinkedInReadProviderError("LinkedIn snapshot next page is invalid")
    start = int(starts[0])
    if start <= current_start or start > 1_000_000_000:
        raise LinkedInReadProviderError("LinkedIn snapshot next page is invalid")
    return start


def snapshot_page(
    result: ApiResult,
    domain: str,
    start: int,
    limit: int,
) -> dict[str, Any]:
    """Serialize one documented Member Snapshot page without field guessing."""
    if result.no_data and result.status == 404:
        return {
            "status": 200,
            "observed_at": observed_at(),
            "data": [],
            "meta": {
                "domain": domain,
                "next_start": None,
                "complete": True,
                "snapshot": True,
            },
        }
    if result.status != 200:
        return terminal_payload(result)
    elements = _objects(result.payload.get("elements"), "snapshot elements")
    if len(elements) != 1:
        raise LinkedInReadProviderError(
            "LinkedIn snapshot response must contain exactly one domain"
        )
    element = elements[0]
    if element.get("snapshotDomain") != domain:
        raise LinkedInReadProviderError("LinkedIn snapshot domain does not match")
    records = _objects(element.get("snapshotData"), "snapshot data")
    if len(records) > limit:
        raise LinkedInReadProviderError("LinkedIn snapshot page exceeds the item limit")
    next_start = _next_start(result.payload, domain, start)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "domain": domain,
            "next_start": next_start,
            "complete": False,
            "snapshot": True,
        },
    }
