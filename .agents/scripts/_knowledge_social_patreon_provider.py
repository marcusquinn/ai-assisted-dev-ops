#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Patreon API v2 creator reader."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPRedirectHandler, Request, build_opener

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

API_ROOT = "https://www.patreon.com/api/oauth2/v2"
MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
BASE_SCOPES = frozenset({"identity", "campaigns"})
OPTIONAL_READ_SCOPES = frozenset({"campaigns.posts", "campaigns.members"})
ALLOWED_SCOPES = BASE_SCOPES | OPTIONAL_READ_SCOPES
SENSITIVE_SCOPES = frozenset(
    {
        "identity[email]",
        "identity.memberships",
        "campaigns.members[email]",
        "campaigns.members.address",
    }
)
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


class PatreonReadProviderError(RuntimeError):
    """Raised for a privacy-safe local provider failure."""


class RejectRedirects(HTTPRedirectHandler):
    """Reject redirects so bearer credentials never cross origins."""

    def redirect_request(self, *_args: Any, **_kwargs: Any) -> None:
        return None


@dataclass(frozen=True)
class Profile:
    access_token: str
    campaign_ids: tuple[str, ...]
    scopes: frozenset[str]
    pii_key: bytes | None
    member_data_purpose: str | None

    @property
    def member_data_authorized(self) -> bool:
        return (
            "campaigns.members" in self.scopes
            and self.member_data_purpose == "membership-services"
            and self.pii_key is not None
        )


@dataclass(frozen=True)
class ApiResult:
    status: int
    payload: Any
    retry_after: int | None = None


ApiCall = Callable[[Profile, str, dict[str, str]], ApiResult]


def _observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _profile_value(prefix: str, suffix: str) -> str:
    return os.environ.get(f"{prefix}_{suffix}", "").strip()


def _profile(profile: str) -> Profile:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise PatreonReadProviderError("Patreon profile name is invalid")
    prefix = f"PATREON_{profile.upper()}"
    token = _profile_value(prefix, "ACCESS_TOKEN")
    if not token or "\x00" in token or len(token.encode()) > 16 * 1024:
        raise PatreonReadProviderError("Patreon profile access token is missing")
    raw_campaigns = _profile_value(prefix, "CAMPAIGN_IDS")
    if not raw_campaigns:
        raise PatreonReadProviderError("Patreon profile campaign IDs are missing")
    try:
        campaigns = selected_campaign_ids(
            [item.strip() for item in raw_campaigns.split(",") if item.strip()]
        )
    except PatreonAdapterError as error:
        raise PatreonReadProviderError("Patreon profile campaign IDs are invalid") from error
    raw_scopes = _profile_value(prefix, "SCOPES")
    if not raw_scopes:
        raise PatreonReadProviderError("Patreon profile scopes are missing")
    scope_values = tuple(item for item in raw_scopes.replace(",", " ").split() if item)
    scopes = frozenset(scope_values)
    if len(scope_values) != len(scopes):
        raise PatreonReadProviderError("Patreon profile scopes contain duplicates")
    if any(not re.fullmatch(r"[A-Za-z0-9.\[\]:_-]+", item) for item in scopes):
        raise PatreonReadProviderError("Patreon profile scopes are invalid")
    if scopes - ALLOWED_SCOPES or scopes & SENSITIVE_SCOPES or any(
        item.startswith("w:") for item in scopes
    ):
        raise PatreonReadProviderError(
            "Patreon profile includes unsupported or sensitive scopes"
        )
    if not BASE_SCOPES.issubset(scopes):
        raise PatreonReadProviderError("Patreon profile is missing required read scopes")
    raw_key = _profile_value(prefix, "PII_KEY")
    pii_key = raw_key.encode() if raw_key else None
    if pii_key is not None and len(pii_key) < 32:
        raise PatreonReadProviderError("Patreon profile PII key must be at least 32 bytes")
    purpose = _profile_value(prefix, "MEMBER_DATA_PURPOSE") or None
    if purpose not in (None, "membership-services"):
        raise PatreonReadProviderError("Patreon profile member-data purpose is invalid")
    return Profile(token, campaigns, scopes, pii_key, purpose)


def _path_allowed(profile: Profile, path: str) -> bool:
    if path in {"/identity", "/campaigns"}:
        return True
    parts = path.strip("/").split("/")
    if len(parts) not in (2, 3) or parts[0] != "campaigns":
        return False
    try:
        selected = campaign_id(parts[1])
    except PatreonAdapterError:
        return False
    if selected not in profile.campaign_ids:
        return False
    return len(parts) == 2 or parts[2] in {"posts", "members"}


def _retry_after(headers: Any, payload: Any) -> int | None:
    header = headers.get("Retry-After") if headers is not None else None
    if isinstance(header, str) and header.isdigit():
        return min(int(header), 86400)
    if not isinstance(payload, dict):
        return None
    errors = payload.get("errors")
    if not isinstance(errors, list) or not errors or not isinstance(errors[0], dict):
        return None
    value = errors[0].get("retry_after_seconds")
    if isinstance(value, str) and value.isdigit():
        value = int(value)
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return min(value, 86400)


def _decode_json(payload: bytes, field: str) -> Any:
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as error:
        raise PatreonReadProviderError(f"Patreon API returned no valid {field} JSON") from error


def _request(profile: Profile, path: str, params: dict[str, str]) -> ApiResult:
    if not _path_allowed(profile, path):
        raise PatreonReadProviderError("Patreon read route is unsupported")
    query = f"?{urlencode(params)}" if params else ""
    request = Request(
        f"{API_ROOT}{path}{query}",
        headers={
            "Accept": "application/vnd.api+json",
            "Authorization": f"Bearer {profile.access_token}",
            "User-Agent": "aidevops-patreon-knowledge/1",
        },
        method="GET",
    )
    try:
        with build_opener(RejectRedirects).open(request, timeout=60) as response:
            raw = response.read(MAX_RESPONSE_BYTES + 1)
            status = int(response.status)
            headers = response.headers
    except HTTPError as error:
        status = int(error.code)
        headers = error.headers
        raw = error.read(MAX_ERROR_BYTES + 1)
        if 300 <= status < 400:
            return ApiResult(502, {})
        payload = _decode_json(raw, "error") if raw and len(raw) <= MAX_ERROR_BYTES else {}
        return ApiResult(status, {}, _retry_after(headers, payload))
    except (OSError, URLError) as error:
        raise PatreonReadProviderError("Patreon API request failed") from error
    if len(raw) > MAX_RESPONSE_BYTES:
        raise PatreonReadProviderError("Patreon API response exceeds the byte safety limit")
    payload = _decode_json(raw, "response")
    return ApiResult(status, payload, _retry_after(headers, payload))


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
    owned, _next = owned_campaign_ids(campaigns.payload)
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


def _page(
    profile: Profile,
    request: PageRequest,
    identity: dict[str, Any],
    api: ApiCall = _request,
) -> dict[str, Any]:
    data = object_value(identity.get("data"), "verified identity")
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
    observed_at = _observed_at()
    if request.stream == "account":
        records = [
            {
                "kind": "creator_account",
                "remote_id": f"creator_account_{request.account_id}",
                "is_creator": True,
                "campaign_ids": list(request.campaign_ids),
            }
        ]
        next_cursor = None
    else:
        assert request.campaign_id is not None
        path = f"/campaigns/{request.campaign_id}"
        if request.stream == "campaigns":
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
            records = [campaign_record(result.payload, request.campaign_id)]
            next_cursor = None
        elif request.stream == "posts":
            result = api(
                profile,
                f"{path}/posts",
                _page_params(request, {"fields[post]": POST_FIELDS}),
            )
            if result.status != 200:
                return _terminal(result)
            records, next_cursor = post_records(result.payload, request.campaign_id)
        elif request.stream == "benefits":
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
            records = benefit_records(result.payload, request.campaign_id)
            next_cursor = None
        else:
            assert request.stream == "memberships"
            assert profile.pii_key is not None
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
            records, next_cursor = membership_records(
                profile.pii_key, result.payload, request.campaign_id
            )
    if len(records) > request.limit:
        raise PatreonReadProviderError("Patreon page exceeds the configured item safety limit")
    return {
        "status": 200,
        "observed_at": observed_at,
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
