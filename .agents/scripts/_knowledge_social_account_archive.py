#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared provider-neutral archive assembly for account page collectors."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Protocol

from knowledge_social_import import reject_credentials


class AccountPageContext(Protocol):
    connection_id: str
    account: dict[str, Any]
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


@dataclass(frozen=True)
class AccountArchiveRows:
    """Normalized rows carried into the shared account archive envelope."""

    objects: list[dict[str, Any]]
    activities: list[dict[str, Any]]
    coverage: list[dict[str, Any]]


@dataclass(frozen=True)
class AccountArchivePolicy:
    """Provider metadata used to assemble one normalized account page."""

    provider: str
    provenance: str
    handle_key: str
    instance_policy_key: str
    policy_values: tuple[tuple[str, str], ...]

    def build(
        self,
        context: AccountPageContext,
        observed_at: str,
        installation: str,
        rows: AccountArchiveRows,
    ) -> dict[str, Any]:
        """Build and credential-scan the common account archive envelope."""
        account = context.account
        policy = dict(context.policy)
        policy.update(self.policy_values)
        policy[self.instance_policy_key] = installation
        archive = {
            "provider": self.provider,
            "connection_id": context.connection_id,
            "remote_account_id": account.get("id"),
            "exported_at": observed_at,
            "enabled_streams": list(context.enabled_streams),
            "policy": policy,
            "accounts": [
                {
                    "remote_id": account.get("id"),
                    "handle": account.get(self.handle_key),
                    "display_name": account.get("name"),
                    "observed_at": observed_at,
                    "provider_json": {
                        "source": self.provenance,
                        "instance_id": installation,
                        "provider_account_id": account.get("provider_account_id"),
                    },
                }
            ],
            "objects": rows.objects,
            "activities": rows.activities,
            "media": [],
            "coverage": rows.coverage,
        }
        reject_credentials(archive)
        return archive


@dataclass(frozen=True)
class AccountPageNormalizer:
    """Run the shared normalization flow with provider-specific callbacks."""

    archive_policy: AccountArchivePolicy
    observed_at: Callable[[dict[str, Any]], str]
    installation_id: Callable[[Any], str]
    page_data: Callable[[dict[str, Any]], list[dict[str, Any]]]
    object_row: Callable[..., dict[str, Any]]
    activity_row: Callable[..., dict[str, Any]]
    coverage: Callable[[str], list[dict[str, Any]]]

    def normalize(
        self, payload: dict[str, Any], context: AccountPageContext
    ) -> dict[str, Any]:
        reject_credentials(payload)
        observed_at = self.observed_at(payload)
        installation = self.installation_id(context.account.get("instance_id"))
        items = self.page_data(payload)
        rows = AccountArchiveRows(
            [self.object_row(item, context, observed_at, installation) for item in items],
            [self.activity_row(item, context, observed_at, installation) for item in items],
            self.coverage(observed_at),
        )
        return self.archive_policy.build(context, observed_at, installation, rows)
