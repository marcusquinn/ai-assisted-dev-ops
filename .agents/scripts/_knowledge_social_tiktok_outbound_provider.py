#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixture-backed, approval-bound TikTok outbound provider adapter."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from _knowledge_social_outbound import ClaimedOperation
from _knowledge_social_outbound_provider import (
    PreparedProvider,
    ProviderAdapterError,
    ProviderIdentityError,
)
from knowledge_social_store import SocialStoreError, validate_opaque

Transport = Callable[[dict[str, str]], dict[str, str]]
ProviderOutcome = tuple[str | None, str | None]


def _provider_outcome(result: dict[str, str]) -> ProviderOutcome:
    outcome: ProviderOutcome = (None, "provider_unavailable")
    state = result.get("state")
    remote_id = result.get("id") or result.get("publish_id")
    if state == "succeeded" and isinstance(remote_id, str):
        outcome = (validate_opaque(remote_id, "provider_remote_id"), None)
    elif state in ("accepted", "unknown") and isinstance(remote_id, str):
        outcome = (validate_opaque(remote_id, "provider_remote_id"), "runtime")
    return outcome


@dataclass(frozen=True)
class TikTokPreparedProvider(PreparedProvider):
    """Validate the selected TikTok account and one video publish request."""

    claimed: ClaimedOperation
    transport: Transport | None = None

    def _request(self) -> dict[str, str]:
        if self.claimed.provider != "tiktok" or self.claimed.action != "post":
            raise ProviderAdapterError("TikTok action is not allowlisted")
        if self.claimed.payload is None or self.claimed.destination_remote_id is None:
            raise ProviderAdapterError("TikTok post requires caption and media reference")
        return {
            "operation": "publish",
            "account_id": self.claimed.remote_account_id,
            "caption": self.claimed.payload,
            "media_ref": self.claimed.destination_remote_id,
            "idempotency_key": self.claimed.operation_id,
        }

    def verify_identity(self) -> None:
        if self.transport is None:
            raise ProviderIdentityError("TikTok official outbound transport is unavailable")
        try:
            result = self.transport(
                {"operation": "identity", "account_id": self.claimed.remote_account_id}
            )
            actual = validate_opaque(str(result.get("id", "")), "TikTok identity ID")
        except (SocialStoreError, TypeError, ValueError) as error:
            raise ProviderIdentityError("selected TikTok identity could not be verified") from error
        if actual != self.claimed.remote_account_id:
            raise ProviderIdentityError("selected TikTok identity does not match approved account")

    def invoke(self) -> tuple[str | None, str | None]:
        outcome: ProviderOutcome = (None, "provider_unavailable")
        if self.transport is not None:
            try:
                outcome = _provider_outcome(self.transport(self._request()))
            except (ProviderAdapterError, SocialStoreError, TypeError, ValueError):
                outcome = (None, "validation")
        return outcome
