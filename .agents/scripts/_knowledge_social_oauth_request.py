#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared immutable request envelope for identity-bound social pages."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, ClassVar

from knowledge_social_import import canonical_json


@dataclass(frozen=True)
class OAuthPageRequest:
    """Provider-neutral request fields with a provider-specific handle key."""

    HANDLE_KEY: ClassVar[str]

    stream: str
    account_id: str
    provider_account_id: str
    handle: str
    instance_id: str
    position: int
    stop_at: str | None
    limit: int

    def payload(self) -> dict[str, Any]:
        return {
            "action": "page",
            "stream": self.stream,
            "account_id": self.account_id,
            "provider_account_id": self.provider_account_id,
            self.HANDLE_KEY: self.handle,
            "instance_id": self.instance_id,
            "position": self.position,
            "stop_at": self.stop_at,
            "limit": self.limit,
        }

    def evidence_key(self) -> str:
        return canonical_json(self.payload())
