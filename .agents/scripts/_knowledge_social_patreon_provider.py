#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Patreon API v2 creator reader."""

from __future__ import annotations

import argparse
import json
import sys
from datetime import UTC, datetime
from typing import Any

from _knowledge_social_patreon import (
    PageRequest,
    PatreonAdapterError,
    campaign_id,
    parse_page_request,
    provider_id,
    selected_campaign_ids,
)
from _knowledge_social_patreon_contract import (
    benefit_records,
    campaign_record,
    identity_record,
    membership_records,
    object_value,
    owned_campaign_ids,
    post_records,
)
from _knowledge_social_patreon_http import (
    MAX_RESPONSE_BYTES,
    ApiCall,
    ApiResult,
    request as _request,
)
from _knowledge_social_patreon_profile import (
    Profile,
    PatreonReadProviderError,
    profile_from_env as _profile,
)

MAX_REQUEST_BYTES = 32 * 1024
STREAM_SCOPES = {
    "account": frozenset(),
    "campaigns": frozenset(),
    "posts": frozenset({"campaigns.posts"}),
    "memberships": frozenset({"campaigns.members"}),
    "benefits": frozenset(),
}
CAMPAIGN_FIELDS = (
    "created_at,creation_name,currency,is_monthly,is_nsfw,name,patron_count,"
    "published_at,summary,url"
)
POST_FIELDS = "content,is_paid,is_public,published_at,title,url"
BENEFIT_FIELDS = (
    "benefit_type,created_at,description,is_deleted,is_ended,is_published,title"
)
TIER_FIELDS = (
    "amount_cents,created_at,description,edited_at,published,published_at,"
    "requires_shipping,title,url"
)
MEMBER_FIELDS = (
    "currently_entitled_amount_cents,is_free_trial,is_gifted,patron_status,"
    "pledge_cadence"
)


def _observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _terminal(result: ApiResult) -> dict[str, Any]:
    payload: dict[str, Any] = {"status": result.status, "observed_at": _observed_at()}
    if result.retry_after is not None:
        payload["retry_after"] = result.retry_after
    return payload


def _identity(
    profile: Profile, expected_id: str, api: ApiCall = _request
) -> dict[str, Any]:
    identity = api(
        profile,
        "/identity",
        {
            "fields[user]": "is_creator",
            "json-api-use-default-includes": "false",
        },
    )
    if identity.status != 200:
        return _terminal(identity)
    account = identity_record(identity.payload, expected_id)
    campaigns = api(
        profile,
        "/campaigns",
        {"json-api-use-default-includes": "false", "page[count]": "1000"},
    )
    if campaigns.status != 200:
        return _terminal(campaigns)
    owned, next_cursor = owned_campaign_ids(campaigns.payload)
    if next_cursor is not None:
        raise PatreonReadProviderError(
            "Patreon campaign ownership exceeds the bounded identity page"
        )
    if not set(profile.campaign_ids).issubset(owned):
        raise PatreonReadProviderError(
            "selected Patreon campaign is not owned by the authenticated creator"
        )
    remote_id = provider_id(expected_id, "selected account ID")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": {
            "provider_account_id": remote_id,
            "role": "creator",
            "is_creator": account["is_creator"],
            "campaign_ids": list(profile.campaign_ids),
            "member_data_authorized": profile.member_data_authorized,
        },
    }


def _require_stream_scope(profile: Profile, stream: str) -> None:
    if not STREAM_SCOPES[stream].issubset(profile.scopes):
        raise PatreonReadProviderError("Patreon profile is missing required read scopes")
    if stream != "memberships":
        return
    if profile.member_data_purpose != "membership-services":
        raise PatreonReadProviderError(
            "Patreon memberships require the membership-services purpose gate"
        )
    if profile.pii_key is None:
        raise PatreonReadProviderError("Patreon profile PII key is missing")


def _next_campaign(request: PageRequest) -> str | None:
    if request.campaign_id is None:
        return None
    index = request.campaign_ids.index(request.campaign_id)
    return request.campaign_ids[index + 1] if index + 1 < len(request.campaign_ids) else None


def _page_meta(
    request: PageRequest, next_cursor: str | None
) -> dict[str, Any]:
    next_campaign = None if next_cursor is not None else _next_campaign(request)
    return {
        "stream": request.stream,
        "campaign_id": request.campaign_id,
        "next_cursor": next_cursor,
        "next_campaign_id": next_campaign,
        "complete": next_cursor is None and next_campaign is None,
    }


def _page_params(request: PageRequest, fields: dict[str, str]) -> dict[str, str]:
    params = {
        **fields,
        "json-api-use-default-includes": "false",
        "page[count]": str(request.limit),
    }
    if request.cursor is not None:
        params["page[cursor]"] = request.cursor
    return params


def _validate_page_identity(data: dict[str, Any], request: PageRequest) -> None:
    if data.get("provider_account_id") != request.account_id:
        raise PatreonReadProviderError(
            "selected Patreon account does not match the configured connection"
        )
    if tuple(data.get("campaign_ids", ())) != request.campaign_ids:
        raise PatreonReadProviderError(
            "selected Patreon campaign is not owned by the authenticated creator"
        )
    if data.get("member_data_authorized") is not request.member_data_authorized:
        raise PatreonReadProviderError("Patreon member-data authorization changed")


def _campaign_path(request: PageRequest) -> tuple[str, str]:
    if request.campaign_id is None:
        raise PatreonReadProviderError("Patreon stream requires a selected campaign")
    return request.campaign_id, f"/campaigns/{request.campaign_id}"


def _campaign_page(
    profile: Profile, request: PageRequest, api: ApiCall
) -> tuple[list[dict[str, Any]], str | None] | dict[str, Any]:
    campaign, path = _campaign_path(request)
    result = api(
        profile,
        path,
        {
            "fields[campaign]": CAMPAIGN_FIELDS,
            "json-api-use-default-includes": "false",
        },
    )
    if result.status != 200:
        return _terminal(result)
    return [campaign_record(result.payload, campaign)], None


def _post_page(
    profile: Profile, request: PageRequest, api: ApiCall
) -> tuple[list[dict[str, Any]], str | None] | dict[str, Any]:
    campaign, path = _campaign_path(request)
    result = api(
        profile,
        f"{path}/posts",
        _page_params(request, {"fields[post]": POST_FIELDS}),
    )
    if result.status != 200:
        return _terminal(result)
    return post_records(result.payload, campaign)


def _benefit_page(
    profile: Profile, request: PageRequest, api: ApiCall
) -> tuple[list[dict[str, Any]], str | None] | dict[str, Any]:
    campaign, path = _campaign_path(request)
    result = api(
        profile,
        path,
        {
            "fields[benefit]": BENEFIT_FIELDS,
            "fields[campaign]": "name",
            "fields[tier]": TIER_FIELDS,
            "include": "benefits,tiers",
            "json-api-use-default-includes": "false",
        },
    )
    if result.status != 200:
        return _terminal(result)
    return benefit_records(result.payload, campaign), None


def _membership_page(
    profile: Profile, request: PageRequest, api: ApiCall
) -> tuple[list[dict[str, Any]], str | None] | dict[str, Any]:
    campaign, path = _campaign_path(request)
    if profile.pii_key is None:
        raise PatreonReadProviderError("Patreon profile PII key is missing")
    result = api(
        profile,
        f"{path}/members",
        _page_params(
            request,
            {
                "fields[member]": MEMBER_FIELDS,
                "fields[tier]": TIER_FIELDS,
                "include": "currently_entitled_tiers",
            },
        ),
    )
    if result.status != 200:
        return _terminal(result)
    return membership_records(profile.pii_key, result.payload, campaign)


def _account_page(request: PageRequest) -> tuple[list[dict[str, Any]], None]:
    return [
        {
            "kind": "creator_account",
            "remote_id": f"creator_account_{request.account_id}",
            "is_creator": True,
            "campaign_ids": list(request.campaign_ids),
        }
    ], None


def _read_page(
    profile: Profile, request: PageRequest, api: ApiCall
) -> tuple[list[dict[str, Any]], str | None] | dict[str, Any]:
    if request.stream == "account":
        return _account_page(request)
    readers = {
        "campaigns": _campaign_page,
        "posts": _post_page,
        "benefits": _benefit_page,
        "memberships": _membership_page,
    }
    reader = readers.get(request.stream)
    if reader is None:
        raise PatreonReadProviderError("Patreon stream is unsupported")
    return reader(profile, request, api)


def _page(
    profile: Profile,
    request: PageRequest,
    identity: dict[str, Any],
    api: ApiCall = _request,
) -> dict[str, Any]:
    data = object_value(identity.get("data"), "verified identity")
    _validate_page_identity(data, request)
    page = _read_page(profile, request, api)
    if isinstance(page, dict):
        return page
    records, next_cursor = page
    if len(records) > request.limit:
        raise PatreonReadProviderError("Patreon page exceeds the configured item safety limit")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": records,
        "meta": _page_meta(request, next_cursor),
    }


def _request_object(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_REQUEST_BYTES:
        raise PatreonReadProviderError("Patreon read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PatreonReadProviderError("Patreon read request is not valid JSON") from error
    return object_value(request, "read request")


def _dispatch(
    request: dict[str, Any], profile: Profile, api: ApiCall = _request
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise PatreonReadProviderError("Patreon identity request shape is invalid")
        return _identity(
            profile, provider_id(request.get("account_id"), "selected account ID"), api
        )
    if action != "page":
        raise PatreonReadProviderError("Patreon read action is unsupported")
    page_request = parse_page_request(request)
    if page_request.campaign_ids != profile.campaign_ids:
        raise PatreonReadProviderError(
            "selected Patreon campaign is not owned by the authenticated creator"
        )
    _require_stream_scope(profile, page_request.stream)
    identity = _identity(profile, page_request.account_id, api)
    if identity.get("status") != 200:
        return identity
    return _page(profile, page_request, identity, api)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    args = parser.parse_args()
    try:
        request = _request_object(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1))
        payload = _dispatch(request, _profile(args.profile))
        encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        if len(encoded.encode()) > MAX_RESPONSE_BYTES:
            raise PatreonReadProviderError("Patreon read response exceeds the safety limit")
        print(encoded)
        return 0
    except (PatreonReadProviderError, PatreonAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - redact provider, creator, and member internals
        print("ERROR: Patreon read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
