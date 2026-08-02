#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared subprocess runtime for structurally equivalent forum providers."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from dataclasses import dataclass
from functools import partial
from importlib import import_module
from types import ModuleType
from typing import Any, Final

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")


@dataclass(frozen=True)
class ProviderDefinition:
    """Provider-specific names and policy used by the shared runtime."""

    label: str
    environment: str
    credential_suffix: str
    credential_field: str
    auth_suffix: str
    auth_field: str
    auth_error: str
    identity_path: str
    account_name: str
    adapter_error: str
    provider_error: str

    @property
    def profile_fields(self) -> tuple[tuple[str, str, int], ...]:
        """Return the bounded environment fields in ProfileConfig order."""
        return (
            ("BASE_URL", "base URL", 4096),
            (self.credential_suffix, self.credential_field, 16 * 1024),
            ("ORIGIN_KEY", "origin key", 16 * 1024),
            (self.auth_suffix, self.auth_field, 64),
        )


PROVIDERS: Final = {
    "forem": ProviderDefinition(
        label="Forem",
        environment="FOREM",
        credential_suffix="API_KEY",
        credential_field="API key",
        auth_suffix="AUTH_MODE",
        auth_field="auth mode",
        auth_error="Forem profile must declare a user-generated API key",
        identity_path="/api/users/me",
        account_name="username",
        adapter_error="ForemAdapterError",
        provider_error="ForemReadProviderError",
    ),
    "nodebb": ProviderDefinition(
        label="NodeBB",
        environment="NODEBB",
        credential_suffix="BEARER_TOKEN",
        credential_field="bearer token",
        auth_suffix="TOKEN_TYPE",
        auth_field="token type",
        auth_error="NodeBB profile must declare a dedicated user token",
        identity_path="/api/self",
        account_name="userslug",
        adapter_error="NodeBBAdapterError",
        provider_error="NodeBBReadProviderError",
    ),
}


@dataclass(frozen=True)
class ForumProvider:
    """Execute one bounded forum provider using its platform modules."""

    definition: ProviderDefinition
    description: str
    domain: ModuleType
    contract: ModuleType
    http: ModuleType
    routes: ModuleType
    adapter_error: type[Exception]
    provider_error: type[Exception]

    def profile_prefix(self, profile: str) -> str:
        """Validate a profile name and return its environment prefix."""
        if PROFILE_NAME.fullmatch(profile) is None:
            raise self.provider_error(f"{self.definition.label} profile name is invalid")
        return f"{self.definition.environment}_{profile.upper()}"

    def profile_value(self, prefix: str, suffix: str, field: str, limit: int) -> str:
        """Read one bounded, non-empty profile value."""
        value = os.environ.get(f"{prefix}_{suffix}", "")
        if not value or "\x00" in value or len(value.encode()) > limit:
            raise self.provider_error(
                f"{self.definition.label} profile {field} is missing"
            )
        return value

    def profile(self, profile: str) -> Any:
        """Build the provider's validated HTTP profile configuration."""
        prefix = self.profile_prefix(profile)
        values = tuple(
            self.profile_value(prefix, suffix, field, limit)
            for suffix, field, limit in self.definition.profile_fields
        )
        base_url, credential, origin_key, auth_mode = values
        base_url = self.http._canonical_base_url(base_url)
        if auth_mode != self.domain.ACCOUNT_AUTH_MODE:
            raise self.provider_error(self.definition.auth_error)
        return self.http.ProfileConfig(
            base_url,
            credential,
            auth_mode,
            self.http.installation_fingerprint(base_url, origin_key),
        )

    def identity(self, config: Any, opener: Any, expected_id: str) -> dict[str, Any]:
        """Read and normalize the authenticated provider identity."""
        result = self.http.api(config, opener, self.definition.identity_path, {})
        if result.status != 200:
            return self.contract.terminal_payload(result)
        return {
            "status": 200,
            "observed_at": self.contract.observed_at(),
            "data": self.contract.identity_value(
                result.payload, expected_id, config.instance_id
            ),
        }

    def verify_page_account(self, request: Any, data: dict[str, Any], config: Any) -> None:
        """Bind a page request to the identity verified for this connection."""
        expected = self.domain.namespaced_id(
            config.instance_id, "user", request.provider_account_id
        )
        if (
            data.get("instance_id") != request.instance_id
            or data.get("provider_account_id") != request.provider_account_id
            or data.get(self.definition.account_name)
            != getattr(request, self.definition.account_name)
            or request.account_id != expected
        ):
            raise self.provider_error(
                f"selected {self.definition.label} account does not match "
                "the configured connection"
            )

    def dispatch(
        self, request: dict[str, Any], config: Any, opener: Any
    ) -> dict[str, Any]:
        """Dispatch one identity or page read request."""
        action = request.get("action")
        if action == "identity":
            self.contract.exact_keys(request, {"action", "account_id"})
            account_id = self.domain.provider_account_id(request.get("account_id"))
            return self.identity(config, opener, account_id)
        if action != "page":
            raise self.provider_error(
                f"{self.definition.label} read action is unsupported"
            )
        page_request = self.domain.parse_page_request(request)
        if page_request.instance_id != config.instance_id:
            raise self.provider_error(
                f"selected {self.definition.label} installation does not match "
                "the connection"
            )
        identity = self.identity(config, opener, page_request.provider_account_id)
        if identity.get("status") != 200:
            return identity
        data = self.contract.object_value(identity.get("data"), "account verification")
        self.verify_page_account(page_request, data, config)
        result = self.routes.page(
            partial(self.http.api, config, opener), page_request, data
        )
        if isinstance(result, self.contract.ApiResult):
            return self.contract.terminal_payload(result)
        return result

    def emit(self, payload: dict[str, Any]) -> None:
        """Serialize one bounded provider response."""
        encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
        if len(encoded.encode()) > self.http.MAX_RESPONSE_BYTES:
            raise self.provider_error(
                f"{self.definition.label} read response exceeds the safety limit"
            )
        print(encoded)

    def parse_args(self) -> argparse.Namespace:
        """Parse the provider profile selection."""
        parser = argparse.ArgumentParser(description=self.description)
        parser.add_argument("--profile", required=True)
        return parser.parse_args()

    def main(self) -> int:
        """Read, dispatch, and emit one redacted provider request."""
        args = self.parse_args()
        try:
            request = self.contract.request_object(
                sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES
            )
            config = self.profile(args.profile)
            self.emit(self.dispatch(request, config, self.http._http_exports()))
            return 0
        except (self.provider_error, self.adapter_error) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 1
        except Exception:  # noqa: BLE001 - intentionally redact provider internals
            print(
                f"ERROR: {self.definition.label} read provider request failed",
                file=sys.stderr,
            )
            return 1


def build_provider(name: str, description: str) -> ForumProvider:
    """Load one allowlisted provider's modules and bind the shared runtime."""
    definition = PROVIDERS.get(name)
    if definition is None:
        raise ValueError("shared forum provider is unsupported")
    module_prefix = f"_knowledge_social_{name}"
    domain = import_module(module_prefix)
    contract = import_module(f"{module_prefix}_contract")
    return ForumProvider(
        definition=definition,
        description=description,
        domain=domain,
        contract=contract,
        http=import_module(f"{module_prefix}_http"),
        routes=import_module(f"{module_prefix}_routes"),
        adapter_error=getattr(domain, definition.adapter_error),
        provider_error=getattr(contract, definition.provider_error),
    )


def provider_functions(name: str, description: str) -> tuple[Any, Any, Any, Any]:
    """Return the stable module-level callables exposed by provider shims."""
    provider = build_provider(name, description)
    return provider.profile, provider.dispatch, provider.parse_args, provider.main
