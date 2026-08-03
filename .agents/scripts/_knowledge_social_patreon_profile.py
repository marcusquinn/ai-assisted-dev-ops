#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Minimal Patreon creator profile and scope configuration."""

from __future__ import annotations

import os
import re
from dataclasses import dataclass

from _knowledge_social_patreon_types import PatreonAdapterError, selected_campaign_ids

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


class PatreonReadProviderError(RuntimeError):
    """Raised for a privacy-safe local provider failure."""


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


def _profile_value(prefix: str, suffix: str) -> str:
    return os.environ.get(f"{prefix}_{suffix}", "").strip()


def _access_token(prefix: str) -> str:
    token = _profile_value(prefix, "ACCESS_TOKEN")
    if not token or "\x00" in token or len(token.encode()) > 16 * 1024:
        raise PatreonReadProviderError("Patreon profile access token is missing")
    return token


def _campaigns(prefix: str) -> tuple[str, ...]:
    raw = _profile_value(prefix, "CAMPAIGN_IDS")
    if not raw:
        raise PatreonReadProviderError("Patreon profile campaign IDs are missing")
    try:
        return selected_campaign_ids([item.strip() for item in raw.split(",") if item.strip()])
    except PatreonAdapterError as error:
        raise PatreonReadProviderError("Patreon profile campaign IDs are invalid") from error


def _scope_values(prefix: str) -> tuple[str, ...]:
    raw = _profile_value(prefix, "SCOPES")
    if not raw:
        raise PatreonReadProviderError("Patreon profile scopes are missing")
    return tuple(item for item in raw.replace(",", " ").split() if item)


def _scopes(prefix: str) -> frozenset[str]:
    values = _scope_values(prefix)
    scopes = frozenset(values)
    if len(values) != len(scopes):
        raise PatreonReadProviderError("Patreon profile scopes contain duplicates")
    if any(re.fullmatch(r"[A-Za-z0-9.\[\]:_-]+", item) is None for item in scopes):
        raise PatreonReadProviderError("Patreon profile scopes are invalid")
    if scopes - ALLOWED_SCOPES or scopes & SENSITIVE_SCOPES:
        raise PatreonReadProviderError("Patreon profile includes unsupported or sensitive scopes")
    if any(item.startswith("w:") for item in scopes):
        raise PatreonReadProviderError("Patreon profile includes unsupported or sensitive scopes")
    if not BASE_SCOPES.issubset(scopes):
        raise PatreonReadProviderError("Patreon profile is missing required read scopes")
    return scopes


def _member_gate(prefix: str) -> tuple[bytes | None, str | None]:
    raw_key = _profile_value(prefix, "PII_KEY")
    pii_key = raw_key.encode() if raw_key else None
    if pii_key is not None and len(pii_key) < 32:
        raise PatreonReadProviderError("Patreon profile PII key must be at least 32 bytes")
    purpose = _profile_value(prefix, "MEMBER_DATA_PURPOSE") or None
    if purpose not in (None, "membership-services"):
        raise PatreonReadProviderError("Patreon profile member-data purpose is invalid")
    return pii_key, purpose


def profile_from_env(profile: str) -> Profile:
    """Load and validate one exact lowercase Patreon profile."""
    if PROFILE_NAME.fullmatch(profile) is None:
        raise PatreonReadProviderError("Patreon profile name is invalid")
    prefix = f"PATREON_{profile.upper()}"
    pii_key, purpose = _member_gate(prefix)
    return Profile(_access_token(prefix), _campaigns(prefix), _scopes(prefix), pii_key, purpose)
