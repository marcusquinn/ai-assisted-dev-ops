#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Guarded live and fixture readers for the read-only Discord adapter."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from _knowledge_social_discord import (
    DiscordAdapterError,
    DiscordProviderUnavailableError,
    PageRequest,
    snowflake,
)
from _knowledge_social_fixture import FixtureSequence
from _knowledge_social_oauth_reader import GuardedOAuthPolicy, GuardedOAuthReader
from knowledge_social_import import reject_credentials

READ_TIMEOUT_SECONDS = 120
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
SAFE_PROVIDER_FAILURES = (
    "Discord bot profile token is missing",
    "Discord bot profile configuration is invalid",
    "Discord identity does not match the configured connection",
    "Discord account export is unavailable",
    "Discord gateway event spool is unavailable",
)


def _decode_output(output: str) -> dict[str, Any]:
    if len(output.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise DiscordAdapterError("Discord read response exceeds the safety limit")
    try:
        payload = json.loads(output)
    except json.JSONDecodeError as error:
        raise DiscordAdapterError("Discord read provider returned no valid JSON") from error
    if not isinstance(payload, dict):
        raise DiscordAdapterError("Discord read response root must be an object")
    return payload


def _provider_failure(stderr: str) -> DiscordProviderUnavailableError:
    for message in SAFE_PROVIDER_FAILURES:
        if f"ERROR: {message}" in stderr:
            return DiscordProviderUnavailableError(message)
    return DiscordProviderUnavailableError("Discord read provider is unavailable")


DISCORD_BOT_POLICY = GuardedOAuthPolicy(
    "Discord",
    "DISCORD",
    "DISCORD_READ_LOG",
    READ_TIMEOUT_SECONDS,
    _decode_output,
    _provider_failure,
    DiscordProviderUnavailableError,
    (
        "BOT_TOKEN",
        "APPLICATION_ID",
        "GUILD_ID",
        "CHANNEL_IDS",
        "THREAD_IDS",
        "DM_CHANNEL_IDS",
        "MESSAGE_CONTENT_INTENT",
        "GUILD_MEMBERS_INTENT",
        "EXPORT_USER_ID",
        "EXPORT_PATH",
        "GATEWAY_EVENTS_PATH",
    ),
    "bot",
)


class GuardedDiscordBot(GuardedOAuthReader):
    """Execute only identity and allowlisted GET/local-replay reads."""

    def __init__(self, helper: Path, profile: str) -> None:
        super().__init__(helper, profile, DISCORD_BOT_POLICY)


def _fixture_page(entry: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    expectation = entry.get("expect_request", {})
    if not isinstance(expectation, dict):
        raise DiscordAdapterError("Discord fixture expectation must be an object")
    actual = request.payload()
    if any(actual.get(key) != value for key, value in expectation.items()):
        raise DiscordAdapterError("Discord request did not resume at the checkpoint")
    response = entry.get("response", entry)
    if not isinstance(response, dict):
        raise DiscordAdapterError("Discord fixture page must be an object")
    return response


class FixtureDiscord:
    """Deterministic provider substitute for Discord collection fixtures."""

    def __init__(self, path: Path) -> None:
        self.fixture = FixtureSequence(path, "Discord", DiscordAdapterError)

    def identity(self, expected_id: str) -> dict[str, Any]:
        del expected_id
        return self.fixture.identity()

    def page(self, request: PageRequest) -> dict[str, Any]:
        return _fixture_page(self.fixture.next_page(), request)


def _bool(value: Any, field: str) -> bool:
    if not isinstance(value, bool):
        raise DiscordAdapterError(f"Discord {field} must be boolean")
    return value


def verified_identity(payload: dict[str, Any], expected_id: str) -> dict[str, Any]:
    """Validate application, bot, guild, allowlists, and export user binding."""
    reject_credentials(payload)
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise DiscordAdapterError("Discord identity returned no account")
    bot_id = snowflake(data.get("id"), "bot user ID")
    if bot_id != expected_id:
        raise DiscordAdapterError("Discord identity does not match the configured connection")
    result = {
        "id": bot_id,
        "application_id": snowflake(data.get("application_id"), "application ID"),
        "guild_id": snowflake(data.get("guild_id"), "guild ID"),
        "channel_ids": data.get("channel_ids"),
        "thread_ids": data.get("thread_ids"),
        "dm_channel_ids": data.get("dm_channel_ids"),
        "message_content_intent": _bool(
            data.get("message_content_intent"), "message-content intent"
        ),
        "guild_members_intent": _bool(
            data.get("guild_members_intent"), "guild-members intent"
        ),
        "export_user_id": data.get("export_user_id"),
    }
    for field in ("channel_ids", "thread_ids", "dm_channel_ids"):
        values = result[field]
        if not isinstance(values, list):
            raise DiscordAdapterError(f"Discord {field} must be an array")
        result[field] = [snowflake(value, field) for value in values]
    if result["export_user_id"] is not None:
        result["export_user_id"] = snowflake(result["export_user_id"], "export user ID")
    return result
