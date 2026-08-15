#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Registry-backed provider adapters for approved outbound operations."""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Protocol

from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_x import XAdapterError, response_status
from _knowledge_social_x_reader import GuardedXurl, verified_identity
from _knowledge_social_provider_common import (
    DEFAULT_PROVIDER_RETRY_SECONDS,
    MAX_PROVIDER_OUTPUT_BYTES,
    MAX_PROVIDER_RETRY_SECONDS,
    WRITE_TIMEOUT_SECONDS,
    PreparedProvider,
    ProviderAdapterError,
    ProviderIdentityError,
    ProviderRateLimitError,
    provider_retry_seconds,
    raise_for_provider_rate_limit,
    redirect_free_provider_open,
)
from _knowledge_social_reddit_outbound_provider import prepare_reddit
from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError, validate_opaque

__all__ = ["DEFAULT_PROVIDER_RETRY_SECONDS", "prepare_provider"]


def _profile_args(claimed: ClaimedOperation) -> list[str]:
    options = (
        ("--app", claimed.app_profile),
        ("--username", claimed.username),
    )
    return [part for option, value in options if value for part in (option, value)]


def _write_args(claimed: ClaimedOperation) -> list[str]:
    if claimed.action == "post" and claimed.payload is not None:
        return ["post", claimed.payload]
    if (
        claimed.action == "reply"
        and claimed.target_remote_id is not None
        and claimed.payload is not None
    ):
        return ["reply", claimed.target_remote_id, claimed.payload]
    if claimed.action in ("like", "bookmark") and claimed.target_remote_id:
        return [claimed.action, claimed.target_remote_id]
    raise ProviderAdapterError("approved outbound operation has an invalid action shape")


def _decoded_response(output: str) -> dict[str, object]:
    if len(output.encode("utf-8")) > MAX_PROVIDER_OUTPUT_BYTES:
        raise ProviderAdapterError("xurl write response exceeds the safety limit")
    try:
        response = json.loads(output)
    except json.JSONDecodeError as error:
        raise ProviderAdapterError("xurl write response is not valid JSON") from error
    if not isinstance(response, dict):
        raise ProviderAdapterError("xurl write response root must be an object")
    reject_credentials(response)
    status = response_status(response)
    if status < 200 or status >= 300:
        raise ProviderAdapterError("xurl write response reports a provider failure")
    return response


def _receipt_remote_id(
    claimed: ClaimedOperation, response: dict[str, object]
) -> str:
    if claimed.action in ("like", "bookmark"):
        if claimed.target_remote_id is None:
            raise ProviderAdapterError("engagement receipt has no target ID")
        return claimed.target_remote_id
    data = response.get("data", response)
    remote_id = data.get("id") if isinstance(data, dict) else None
    if not isinstance(remote_id, str):
        raise ProviderAdapterError("xurl write response has no stable post ID")
    return validate_opaque(remote_id, "provider_remote_id")


def _provider_remote_id(claimed: ClaimedOperation, output: str) -> str:
    return _receipt_remote_id(claimed, _decoded_response(output))


def invoke_provider(
    helper: Path, claimed: ClaimedOperation
) -> tuple[str | None, str | None]:
    """Invoke one fixed helper action and classify only privacy-safe outcomes."""
    write_args = _write_args(claimed)
    command = [
        str(helper),
        write_args[0],
        *_profile_args(claimed),
        "--confirm-write",
        "--",
        *write_args[1:],
    ]
    try:
        completed = subprocess.run(  # nosec B603 -- fixed helper and allowlisted action argv
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=WRITE_TIMEOUT_SECONDS,
        )
    except (OSError, subprocess.SubprocessError):
        return None, "provider_unavailable"
    if completed.returncode != 0:
        return None, "provider_unavailable"
    try:
        return _provider_remote_id(claimed, completed.stdout), None
    except (ProviderAdapterError, SocialStoreError, UnicodeError, XAdapterError):
        return None, "validation"


@dataclass(frozen=True)
class XPreparedProvider:
    """Prepared official X CLI invocation for one claimed operation."""

    helper: Path
    claimed: ClaimedOperation

    def verify_identity(self) -> None:
        try:
            identity_reader = GuardedXurl(
                self.helper, self.claimed.app_profile, self.claimed.username
            )
            verified_identity(
                identity_reader.identity(), self.claimed.remote_account_id
            )
        except (
            OSError,
            SocialStoreError,
            subprocess.SubprocessError,
            XAdapterError,
        ) as error:
            raise ProviderIdentityError(
                "selected provider identity could not be verified"
            ) from error

    def invoke(self) -> tuple[str | None, str | None]:
        return invoke_provider(self.helper, self.claimed)


def _prepare_x(claimed: ClaimedOperation) -> PreparedProvider:
    return XPreparedProvider(Path(__file__).with_name("xurl-helper.sh"), claimed)


def _prepare_reddit(claimed: ClaimedOperation) -> PreparedProvider:
    return prepare_reddit(claimed)


def _prepare_meta(claimed: ClaimedOperation) -> PreparedProvider:
    from _knowledge_social_meta_outbound_provider import MetaPreparedProvider

    return MetaPreparedProvider(claimed)


def _prepare_tiktok(claimed: ClaimedOperation) -> PreparedProvider:
    from _knowledge_social_tiktok_outbound_provider import TikTokPreparedProvider

    return TikTokPreparedProvider(claimed)


def _prepare_linkedin(claimed: ClaimedOperation) -> PreparedProvider:
    from _knowledge_social_linkedin_outbound_provider import LinkedInPreparedProvider

    return LinkedInPreparedProvider(claimed)


def _prepare_youtube(claimed: ClaimedOperation) -> PreparedProvider:
    from _knowledge_social_youtube_outbound_provider import YouTubePreparedProvider

    return YouTubePreparedProvider(claimed)


PROVIDER_FACTORIES: dict[str, Callable[[ClaimedOperation], PreparedProvider]] = {
    "linkedin": _prepare_linkedin,
    "meta_facebook": _prepare_meta,
    "meta_instagram": _prepare_meta,
    "meta_threads": _prepare_meta,
    "reddit": _prepare_reddit,
    "tiktok": _prepare_tiktok,
    "xapi": _prepare_x,
    "youtube": _prepare_youtube,
}


def prepare_provider(claimed: ClaimedOperation) -> PreparedProvider:
    """Resolve one allowlisted provider without accepting executable input."""
    factory = PROVIDER_FACTORIES.get(claimed.provider)
    if factory is None:
        raise ProviderAdapterError("approved outbound provider is unsupported")
    return factory(claimed)
