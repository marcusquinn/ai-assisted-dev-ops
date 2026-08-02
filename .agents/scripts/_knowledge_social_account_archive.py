#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared provider-neutral archive assembly for account page collectors."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Protocol

from knowledge_social_import import reject_credentials


class AccountPageContext(Protocol):
    connection_id: str
    account: dict[str, Any]
    enabled_streams: tuple[str, ...]
    policy: dict[str, Any]


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
        objects: list[dict[str, Any]],
        activities: list[dict[str, Any]],
        coverage: list[dict[str, Any]],
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
            "objects": objects,
            "activities": activities,
            "media": [],
            "coverage": coverage,
        }
        reject_credentials(archive)
        return archive
