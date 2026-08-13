#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixture-backed, approval-bound Meta outbound provider adapter.

The production boundary intentionally stays unavailable until an operator wires
an official transport.  Tests inject a small transport instead, keeping tokens,
campaign bodies, and undocumented endpoint guesses outside this module.
"""

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

META_PRODUCTS = {
    "meta_facebook": "facebook",
    "meta_instagram": "instagram",
    "meta_threads": "threads",
}
Transport = Callable[[dict[str, str]], dict[str, str]]
ProviderOutcome = tuple[str | None, str | None]


def _product(claimed: ClaimedOperation) -> str:
    product = META_PRODUCTS.get(claimed.provider)
    if product is None:
        raise ProviderAdapterError("Meta provider is not allowlisted")
    return product


def _request(claimed: ClaimedOperation) -> dict[str, str]:
    product = _product(claimed)
    if claimed.payload is None:
        raise ProviderAdapterError("Meta write requires an approved private body")
    request = {
        "operation": "publish",
        "product": product,
        "action": claimed.action,
        "account_id": claimed.remote_account_id,
        "body": claimed.payload,
        "idempotency_key": claimed.operation_id,
    }
    if claimed.target_remote_id is not None:
        request["target_id"] = claimed.target_remote_id
    if claimed.destination_remote_id is not None:
        request["media_ref"] = claimed.destination_remote_id
    return request


def _provider_outcome(result: dict[str, str]) -> ProviderOutcome:
    outcome: ProviderOutcome = (None, "provider_unavailable")
    state = result.get("state")
    remote_id = result.get("id") or result.get("job_id")
    if state == "succeeded" and isinstance(remote_id, str):
        outcome = (validate_opaque(remote_id, "provider_remote_id"), None)
    elif state in ("accepted", "unknown") and isinstance(remote_id, str):
        outcome = (validate_opaque(remote_id, "provider_remote_id"), "runtime")
    return outcome


@dataclass(frozen=True)
class MetaPreparedProvider(PreparedProvider):
    """Validate one selected Meta product before its official write transport."""

    claimed: ClaimedOperation
    transport: Transport | None = None

    def verify_identity(self) -> None:
        product = _product(self.claimed)
        if self.transport is None:
            raise ProviderIdentityError("Meta official outbound transport is unavailable")
        try:
            result = self.transport(
                {
                    "operation": "identity",
                    "product": product,
                    "account_id": self.claimed.remote_account_id,
                }
            )
            actual = validate_opaque(str(result.get("id", "")), "Meta identity ID")
        except (SocialStoreError, TypeError, ValueError) as error:
            raise ProviderIdentityError("selected Meta identity could not be verified") from error
        if actual != self.claimed.remote_account_id:
            raise ProviderIdentityError("selected Meta identity does not match approved account")

    def invoke(self) -> tuple[str | None, str | None]:
        outcome: ProviderOutcome = (None, "provider_unavailable")
        if self.transport is not None:
            try:
                outcome = _provider_outcome(self.transport(_request(self.claimed)))
            except (SocialStoreError, TypeError, ValueError):
                outcome = (None, "validation")
        return outcome
