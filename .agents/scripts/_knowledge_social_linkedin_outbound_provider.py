#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Official, capability-gated LinkedIn text-post adapter for approved intents."""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.request import Request

from _knowledge_social_linkedin import API_VERSION
from _knowledge_social_linkedin_provider import PROFILE_NAME, _access_token
from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_outbound_provider import (
    ProviderAdapterError,
    ProviderIdentityError,
    ProviderRateLimitError,
    redirect_free_provider_open,
    raise_for_provider_rate_limit,
)
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

API_BASE = "https://api.linkedin.com/rest"
POST_ENDPOINT = "posts"
IDENTITY_ENDPOINT = "memberAuthorizations"
MAX_RESPONSE_BYTES = 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
UrlOpen = Callable[..., Any]


def _profile(claimed: ClaimedOperation) -> str:
    if claimed.app_profile is None or PROFILE_NAME.fullmatch(claimed.app_profile) is None:
        raise ProviderAdapterError("LinkedIn outbound operations require a named OAuth profile")
    return claimed.app_profile


def _decode_response(payload: bytes) -> dict[str, Any]:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise ProviderAdapterError("LinkedIn write response exceeds the safety limit")
    try:
        decoded = json.loads(payload.decode("utf-8")) if payload else {}
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ProviderAdapterError("LinkedIn write response is not valid JSON") from error
    if not isinstance(decoded, dict):
        raise ProviderAdapterError("LinkedIn write response root must be an object")
    reject_credentials(decoded)
    return decoded


def _request(token: str, endpoint: str, *, method: str, data: bytes | None = None) -> Request:
    endpoint_name = endpoint.split("?", 1)[0]
    if endpoint_name not in (IDENTITY_ENDPOINT, POST_ENDPOINT):
        raise ProviderAdapterError("LinkedIn write endpoint is not allowlisted")
    return Request(
        f"{API_BASE}/{endpoint}",
        data=data,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "Linkedin-Version": API_VERSION,
            "User-Agent": "aidevops-linkedin-outbound/1",
            "X-Restli-Protocol-Version": "2.0.0",
        },
        method=method,
    )


def _member_id(payload: dict[str, Any]) -> str:
    elements = payload.get("elements")
    if not isinstance(elements, list) or len(elements) != 1:
        raise ProviderIdentityError("LinkedIn outbound capability or identity is unavailable")
    member_id = elements[0].get("member") if isinstance(elements[0], dict) else None
    if not isinstance(member_id, str):
        raise ProviderIdentityError("LinkedIn outbound capability or identity is unavailable")
    return validate_opaque(member_id, "provider_remote_id")


@dataclass(frozen=True)
class LinkedInPreparedProvider:
    """Prepared official LinkedIn post route with exact member binding."""

    claimed: ClaimedOperation
    opener: UrlOpen = redirect_free_provider_open

    def verify_identity(self) -> None:
        try:
            token = _access_token(_profile(self.claimed))
            request = _request(
                token, f"{IDENTITY_ENDPOINT}?q=memberAndApplication", method="GET"
            )
            with self.opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
                status = getattr(response, "status", 200)
                raise_for_provider_rate_limit(status, response.headers)
                if status != 200:
                    raise ProviderIdentityError("LinkedIn outbound capability or identity is unavailable")
                member_id = _member_id(
                    _decode_response(response.read(MAX_RESPONSE_BYTES + 1))
                )
            if member_id != self.claimed.remote_account_id:
                raise ProviderIdentityError(
                    "selected LinkedIn member does not match the approved account"
                )
        except ProviderIdentityError:
            raise
        except ProviderRateLimitError:
            raise
        except HTTPError as error:
            raise_for_provider_rate_limit(error.code, error.headers)
            raise ProviderIdentityError(
                "LinkedIn outbound capability or identity is unavailable"
            ) from None
        except (URLError, OSError, SocialStoreError, ProviderAdapterError):
            raise ProviderIdentityError("LinkedIn outbound capability or identity is unavailable") from None

    def _post(self) -> tuple[str | None, str | None]:
        if self.claimed.action != "post" or self.claimed.payload is None:
            return None, "validation"
        token = _access_token(_profile(self.claimed))
        body = json.dumps(
            {
                "author": self.claimed.remote_account_id,
                "commentary": self.claimed.payload,
                "visibility": "PUBLIC",
                "distribution": {
                    "feedDistribution": "MAIN_FEED",
                    "targetEntities": [],
                    "thirdPartyDistributionChannels": [],
                },
                "lifecycleState": "PUBLISHED",
                "isReshareDisabledByAuthor": False,
            },
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")
        with self.opener(
            _request(token, POST_ENDPOINT, method="POST", data=body),
            timeout=HTTP_TIMEOUT_SECONDS,
        ) as response:
            status = getattr(response, "status", 201)
            raise_for_provider_rate_limit(status, response.headers)
            if status not in (200, 201):
                return None, "provider_unavailable"
            remote_id = response.headers.get("x-restli-id")
            if not isinstance(remote_id, str) or not remote_id:
                payload = _decode_response(response.read(MAX_RESPONSE_BYTES + 1))
                remote_id = payload.get("id")
            if not isinstance(remote_id, str):
                return None, "validation"
            return validate_opaque(remote_id, "provider_remote_id"), None

    def invoke(self) -> tuple[str | None, str | None]:
        try:
            return self._post()
        except ProviderRateLimitError:
            raise
        except HTTPError as error:
            raise_for_provider_rate_limit(error.code, error.headers)
            return None, "provider_unavailable"
        except (URLError, OSError):
            return None, "provider_unavailable"
        except (SocialStoreError, ProviderAdapterError, UnicodeError):
            return None, "validation"
