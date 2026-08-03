#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only beehiiv publication subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from datetime import UTC, datetime
from functools import partial
from typing import Any, Callable

from _knowledge_social_beehiiv import (
    BeehiivAdapterError,
    BeehiivProviderError,
    PageMetadata,
    PageRequest,
    parse_page_request,
    publication_id,
    validate_page_metadata,
)
from _knowledge_social_beehiiv_http import (
    MAX_RESPONSE_BYTES,
    ApiResult,
    Opener,
    ProfileConfig,
    api,
    http_opener,
)
from _knowledge_social_beehiiv_posts import normalize_post, validated_text
from knowledge_social_import import reject_credentials

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
Api = Callable[[str, dict[str, str]], ApiResult]


def _observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise BeehiivProviderError("beehiiv profile name is invalid")
    return f"BEEHIIV_{profile.upper()}"


def _value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise BeehiivProviderError(f"beehiiv profile {field} is missing")
    return value


def _profile(profile: str) -> ProfileConfig:
    prefix = _prefix(profile)
    token = _value(prefix, "ACCESS_TOKEN", "access token", 16 * 1024)
    selected = publication_id(_value(prefix, "PUBLICATION_ID", "publication ID", 128))
    name = _value(prefix, "PUBLICATION_NAME", "publication name", 4096)
    organization = _value(prefix, "ORGANIZATION_NAME", "organization name", 4096)
    ownership = publication_id(
        _value(
            prefix,
            "CREATOR_OWNED_PUBLICATION_ID",
            "creator-owned publication ID",
            128,
        )
    )
    if ownership != selected:
        raise BeehiivProviderError(
            "beehiiv profile creator ownership attestation does not match publication"
        )
    return ProfileConfig(token, selected, name, organization, ownership)


def _object(value: Any, field: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise BeehiivProviderError(f"beehiiv {field} must be an object")
    return value


def _objects(value: Any, field: str, limit: int) -> list[dict[str, Any]]:
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise BeehiivProviderError(f"beehiiv {field} must be an array")
    if len(value) > limit:
        raise BeehiivProviderError(f"beehiiv {field} exceeds the item limit")
    return value


def _non_negative_int(value: Any, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise BeehiivProviderError(f"beehiiv {field} is invalid")
    return value


def _terminal(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": _observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _identity(
    config: ProfileConfig, opener: Opener, expected_id: str
) -> dict[str, Any]:
    if publication_id(expected_id) != config.publication_id:
        raise BeehiivProviderError(
            "selected beehiiv publication does not match the configured publication"
        )
    if config.creator_owned_publication_id != config.publication_id:
        raise BeehiivProviderError(
            "beehiiv profile creator ownership attestation does not match publication"
        )
    result = api(config, opener, "/publications", {"limit": "2", "page": "1"})
    if result.status != 200:
        return _terminal(result)
    root = _object(result.payload, "publications response")
    reject_credentials(root)
    items = _objects(root.get("data"), "publications", 2)
    page = _non_negative_int(root.get("page"), "publication page")
    total_pages = _non_negative_int(root.get("total_pages"), "publication total pages")
    total_results = _non_negative_int(root.get("total_results"), "publication total results")
    if page != 1 or total_pages != 1 or total_results != 1 or len(items) != 1:
        raise BeehiivProviderError(
            "beehiiv credential is not bound to exactly one visible publication"
        )
    item = items[0]
    selected = publication_id(item.get("id"))
    name = validated_text(item.get("name"), "publication name")
    organization = validated_text(item.get("organization_name"), "organization name")
    created = item.get("created")
    referral = item.get("referral_program_enabled")
    if (
        selected != config.publication_id
        or name != config.publication_name
        or organization != config.organization_name
    ):
        raise BeehiivProviderError("beehiiv publication identity does not match expectations")
    if isinstance(created, bool) or not isinstance(created, (int, float)) or created < 0:
        raise BeehiivProviderError("beehiiv publication creation time is invalid")
    if not isinstance(referral, bool):
        raise BeehiivProviderError("beehiiv publication referral state is invalid")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": {
            "id": selected,
            "name": name,
            "organization_name": organization,
            "created": created,
            "referral_program_enabled": referral,
            "scope_verified": True,
            "ownership_attested": True,
        },
    }


def _posts(api_call: Api, request: PageRequest) -> ApiResult | dict[str, Any]:
    result = api_call(
        f"/publications/{request.account_id}/posts",
        {
            "expand": "free_web_content",
            "limit": str(request.limit),
            "page": str(request.page),
            "status": "confirmed",
            "order_by": "created",
            "direction": "asc",
        },
    )
    if result.status != 200:
        return result
    root = _object(result.payload, "posts response")
    reject_credentials(root)
    items = _objects(root.get("data"), "posts", request.limit)
    page = _non_negative_int(root.get("page"), "post response page")
    total_pages = _non_negative_int(root.get("total_pages"), "post total pages")
    total_results = _non_negative_int(root.get("total_results"), "post total results")
    response_limit = _non_negative_int(root.get("limit"), "post response limit")
    if response_limit != request.limit:
        raise BeehiivProviderError("beehiiv post pagination does not match the request")
    validate_page_metadata(
        PageMetadata(page, total_pages, total_results, len(items)),
        request,
        exact_items=True,
    )
    observed = datetime.now(UTC)
    records = [
        record
        for item in items
        if (record := normalize_post(item, observed.timestamp()))
    ]
    return {
        "status": 200,
        "observed_at": observed.isoformat().replace("+00:00", "Z"),
        "data": records,
        "meta": {
            "stream": request.stream,
            "publication_id": request.account_id,
            "page": page,
            "total_pages": total_pages,
            "total_results": total_results,
        },
    }


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    if request.get("action") == "identity":
        if set(request) != {"action", "account_id"}:
            raise BeehiivProviderError("beehiiv identity request shape is invalid")
        return _identity(config, opener, publication_id(request.get("account_id")))
    page_request = parse_page_request(request)
    identity = _identity(config, opener, page_request.account_id)
    if identity.get("status") != 200:
        return identity
    data = _object(identity.get("data"), "publication verification")
    if (
        data.get("id") != page_request.account_id
        or data.get("scope_verified") is not True
        or data.get("ownership_attested") is not True
    ):
        raise BeehiivProviderError("beehiiv page publication identity is not verified")
    result = _posts(partial(api, config, opener), page_request)
    return _terminal(result) if isinstance(result, ApiResult) else result


def _request_object(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_REQUEST_BYTES:
        raise BeehiivProviderError("beehiiv request exceeds the safety limit")
    try:
        value = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise BeehiivProviderError("beehiiv request is invalid") from error
    if not isinstance(value, dict):
        raise BeehiivProviderError("beehiiv request must be an object")
    reject_credentials(value)
    return value


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise BeehiivProviderError("beehiiv response exceeds the safety limit")
    print(encoded)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        request = _request_object(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1))
        _emit(_dispatch(request, _profile(args.profile), http_opener()))
        return 0
    except (BeehiivProviderError, BeehiivAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: beehiiv request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
