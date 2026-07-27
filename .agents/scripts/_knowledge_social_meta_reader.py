#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for Meta product data."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Protocol

from _knowledge_social_collect_cli import guarded_reader_environment
from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_meta import (
    MetaAdapterError,
    MetaProviderUnavailableError,
    PageRequest,
    account_id,
    product_spec,
)
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Python urllib HTTP exports are unavailable",
    "Meta OAuth profile access token is missing",
    "Meta OAuth profile name is invalid",
    "Meta product is unsupported",
)


class MetaReader(Protocol):
    """Minimal GET-only provider surface used by collection."""

    def identity(self, expected_id: str) -> dict[str, Any]: ...

    def page(self, request: PageRequest) -> dict[str, Any]: ...


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise MetaAdapterError("Meta read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise MetaAdapterError("Meta read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise MetaAdapterError("Meta read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> MetaProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return MetaProviderUnavailableError(message)
    return MetaProviderUnavailableError("Meta read provider is unavailable")


META_OAUTH_POLICY = GuardedOAuthPolicy(
    "Meta",
    "META",
    "META_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    MetaProviderUnavailableError,
)


class GuardedMetaOAuth(GuardedOAuthReader):
    """Execute only one product identity and its allowlisted Graph GETs."""

    def __init__(self, helper: Path, profile: str, product: str) -> None:
        product_spec(product)
        self.product = product
        super().__init__(helper, profile, META_OAUTH_POLICY)

    def _environment(self) -> dict[str, str]:
        token_name = f"META_{self.profile.upper()}_{self.product.upper()}_ACCESS_TOKEN"
        return guarded_reader_environment(token_name, ("META_READ_LOG",))

    def identity(self, expected_id: str) -> dict[str, Any]:
        return self.process.run(
            {"action": "identity", "product": self.product, "account_id": expected_id}
        )


def _fixture_page(entry: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    expectation = entry.get("expect_request", {})
    if not isinstance(expectation, dict):
        raise MetaAdapterError("Meta fixture request expectation must be an object")
    actual = request.payload()
    if any(actual.get(key) != value for key, value in expectation.items()):
        raise MetaAdapterError("Meta request did not resume at the expected checkpoint")
    response = entry.get("response", entry)
    if not isinstance(response, dict):
        raise MetaAdapterError("Meta fixture page response must be an object")
    return response


class FixtureMeta:
    """Deterministic OAuth substitute for product pagination and failures."""

    def __init__(self, path: Path, product: str) -> None:
        self.product = product
        self.fixture = FixtureSequence(path, f"Meta {product}", MetaAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        if request.product != self.product:
            raise MetaAdapterError("Meta fixture product does not match the request")
        return _fixture_page(self.fixture.next_page(), request)


def verified_identity(
    payload: dict[str, Any], expected_id: str, product: str
) -> dict[str, Any]:
    """Validate product identity without allowing credential-shaped fields through."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise MetaAdapterError(f"{product} account verification returned no account")
    remote_id = account_id(data.get("id"), "account ID")
    if data.get("product") != product or remote_id != expected_id:
        raise MetaAdapterError(
            f"selected {product} account does not match the configured connection"
        )
    account = {"id": remote_id, "product": product}
    for field in ("username", "name", "category", "is_verified"):
        value = data.get(field)
        if isinstance(value, (str, bool)):
            account[field] = value
    return account
