#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded read-only Discord REST and local replay subprocess."""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import sys
import time
from typing import Any, Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from _knowledge_social_discord_contract import (
    ApiResult,
    DiscordReadProviderError,
    exact_keys,
    identity_value,
    object_value,
    snowflake,
    terminal_payload,
)
from _knowledge_social_discord_routes import page, page_request

API_BASE = "https://discord.com/api/v10"
MAX_REQUEST_BYTES = 64 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
HTTP_TIMEOUT_SECONDS = 60
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
READ_PATH = re.compile(
    r"^/(users/@me|applications/@me|guilds/[0-9]+(?:/(?:channels|roles|members))?|channels/[0-9]+(?:/messages)?)$"
)
UrlOpen = Callable[..., Any]


def _prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise DiscordReadProviderError("Discord bot profile configuration is invalid")
    return f"DISCORD_{profile.upper()}"


def _env(prefix: str, suffix: str, *, required: bool = False) -> str | None:
    value = os.environ.get(f"{prefix}_{suffix}")
    if required and not value:
        message = (
            "Discord bot profile token is missing"
            if suffix == "BOT_TOKEN"
            else "Discord bot profile configuration is invalid"
        )
        raise DiscordReadProviderError(message)
    if value is not None and ("\x00" in value or len(value.encode("utf-8")) > 65536):
        raise DiscordReadProviderError("Discord bot profile configuration is invalid")
    return value


def _ids(value: str | None, field: str) -> tuple[str, ...]:
    if not value:
        return ()
    values = tuple(part.strip() for part in value.split(",") if part.strip())
    result = tuple(snowflake(part, field) or "" for part in values)
    if len(result) != len(set(result)):
        raise DiscordReadProviderError("Discord bot profile configuration is invalid")
    return result


def _flag(value: str | None) -> bool:
    if value is None:
        return False
    if value.lower() not in ("true", "false"):
        raise DiscordReadProviderError("Discord bot profile configuration is invalid")
    return value.lower() == "true"


def _config(profile: str) -> tuple[str, dict[str, Any], str | None, str | None]:
    prefix = _prefix(profile)
    token = _env(prefix, "BOT_TOKEN", required=True) or ""
    config = {
        "application_id": snowflake(
            _env(prefix, "APPLICATION_ID", required=True), "application ID"
        ),
        "guild_id": snowflake(_env(prefix, "GUILD_ID", required=True), "guild ID"),
        "channel_ids": _ids(_env(prefix, "CHANNEL_IDS"), "channel ID"),
        "thread_ids": _ids(_env(prefix, "THREAD_IDS"), "thread ID"),
        "dm_channel_ids": _ids(_env(prefix, "DM_CHANNEL_IDS"), "DM channel ID"),
        "message_content_intent": _flag(_env(prefix, "MESSAGE_CONTENT_INTENT")),
        "guild_members_intent": _flag(_env(prefix, "GUILD_MEMBERS_INTENT")),
        "export_user_id": snowflake(
            _env(prefix, "EXPORT_USER_ID"), "export user ID", optional=True
        ),
    }
    if not any(
        (config["channel_ids"], config["thread_ids"], config["dm_channel_ids"])
    ):
        raise DiscordReadProviderError("Discord bot profile configuration is invalid")
    all_surfaces = (
        *config["channel_ids"],
        *config["thread_ids"],
        *config["dm_channel_ids"],
    )
    if len(all_surfaces) != len(set(all_surfaces)):
        raise DiscordReadProviderError("Discord bot profile configuration is invalid")
    return (
        token,
        config,
        _env(prefix, "EXPORT_PATH"),
        _env(prefix, "GATEWAY_EVENTS_PATH"),
    )


def _request_payload() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise DiscordReadProviderError("Discord read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiscordReadProviderError("Discord read request is not valid JSON") from error
    if not isinstance(request, dict):
        raise DiscordReadProviderError("Discord read request root must be an object")
    return request


def _decode_response(payload: bytes) -> Any:
    if len(payload) > MAX_RESPONSE_BYTES:
        raise DiscordReadProviderError("Discord read response exceeds the safety limit")
    try:
        return json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise DiscordReadProviderError("Discord API returned no valid JSON") from error


def _retry_epoch(value: str | None) -> int | None:
    try:
        seconds = float(value) if value is not None else None
    except ValueError:
        return None
    if seconds is None or not math.isfinite(seconds) or seconds < 0:
        return None
    return int(time.time() + math.ceil(seconds))


def _rate_headers(headers: Any) -> dict[str, str]:
    names = (
        "X-RateLimit-Limit",
        "X-RateLimit-Remaining",
        "X-RateLimit-Reset",
        "X-RateLimit-Reset-After",
        "X-RateLimit-Bucket",
        "X-RateLimit-Scope",
    )
    return {name: value for name in names if (value := headers.get(name)) is not None}


def _api(
    token: str, opener: UrlOpen, endpoint: str, params: dict[str, str]
) -> ApiResult:
    if READ_PATH.fullmatch(endpoint) is None:
        raise DiscordReadProviderError("Discord API endpoint is not allowlisted")
    url = f"{API_BASE}{endpoint}"
    if params:
        url = f"{url}?{urlencode(params)}"
    request = Request(
        url,
        headers={
            "Accept": "application/json",
            "Authorization": f"Bot {token}",
            "User-Agent": "aidevops-discord-knowledge/1",
        },
        method="GET",
    )
    try:
        with opener(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
            status = getattr(response, "status", 200)
            if isinstance(status, bool) or not isinstance(status, int):
                raise DiscordReadProviderError("Discord HTTP status is invalid")
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if not isinstance(payload, bytes):
                raise DiscordReadProviderError("Discord HTTP response is invalid")
            return ApiResult(status, _decode_response(payload), rate_limit=_rate_headers(response.headers))
    except HTTPError as error:
        return ApiResult(
            error.code,
            {},
            _retry_epoch(error.headers.get("Retry-After")),
            _rate_headers(error.headers),
        )
    except (TimeoutError, URLError, OSError) as error:
        raise DiscordReadProviderError("Discord read provider request failed") from error


def _identity(
    api: Callable[[str, dict[str, str]], ApiResult],
    config: dict[str, Any],
    expected_bot_id: str,
) -> dict[str, Any]:
    user = api("/users/@me", {})
    if user.status != 200:
        return terminal_payload(user)
    application = api("/applications/@me", {})
    if application.status != 200:
        return terminal_payload(application)
    guild = api(f"/guilds/{config['guild_id']}", {})
    if guild.status != 200:
        return terminal_payload(guild)
    return {
        "status": 200,
        "observed_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "data": identity_value(
            object_value(user.payload, "current user"),
            object_value(application.payload, "current application"),
            object_value(guild.payload, "guild"),
            config,
            expected_bot_id,
        ),
    }


def _verify_surfaces(
    api: Callable[[str, dict[str, str]], ApiResult], config: dict[str, Any]
) -> dict[str, Any] | None:
    """Prove every allowlisted channel belongs to its declared authority."""
    groups = (
        (config["channel_ids"], {0, 5, 15, 16}, True),
        (config["thread_ids"], {10, 11, 12}, True),
        (config["dm_channel_ids"], {1}, False),
    )
    for channel_ids, allowed_types, guild_surface in groups:
        failure = _verify_surface_group(
            api, channel_ids, allowed_types, config["guild_id"], guild_surface
        )
        if failure is not None:
            return failure
    return None


def _verify_surface_group(
    api: Callable[[str, dict[str, str]], ApiResult],
    channel_ids: tuple[str, ...],
    allowed_types: set[int],
    guild_id: str,
    guild_surface: bool,
) -> dict[str, Any] | None:
    for channel_id in channel_ids:
        result = api(f"/channels/{channel_id}", {})
        if result.status != 200:
            return terminal_payload(result)
        channel = object_value(result.payload, "allowlisted channel")
        channel_type = channel.get("type")
        expected_guild = guild_id if guild_surface else None
        if channel_type not in allowed_types or channel.get("guild_id") != expected_guild:
            raise DiscordReadProviderError(
                "Discord identity does not match the configured connection"
            )
    return None


def _execute(
    raw_request: dict[str, Any],
    api: Callable[[str, dict[str, str]], ApiResult],
    config: dict[str, Any],
    export_path: str | None,
    gateway_path: str | None,
) -> dict[str, Any]:
    action = raw_request.get("action")
    if action == "identity":
        exact_keys(raw_request, {"action", "account_id"})
        account_id = snowflake(raw_request.get("account_id"), "bot user ID")
        return _identity(api, config, account_id or "")
    if action != "page":
        raise DiscordReadProviderError("Discord read action is unsupported")
    request = page_request(raw_request)
    identity = _identity(api, config, request.config["bot_id"])
    if identity.get("status") != 200:
        return identity
    expected_identity = dict(request.config)
    expected_identity["id"] = expected_identity.pop("bot_id")
    for field in ("channel_ids", "thread_ids", "dm_channel_ids"):
        expected_identity[field] = list(expected_identity[field])
    if identity.get("data") != expected_identity:
        raise DiscordReadProviderError(
            "Discord identity does not match the configured connection"
        )
    surface_failure = _verify_surfaces(api, config)
    return surface_failure or page(
        api, request, export_path=export_path, gateway_path=gateway_path
    )


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise DiscordReadProviderError("Discord read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        raw_request = _request_payload()
        token, config, export_path, gateway_path = _config(args.profile)
        api = lambda endpoint, params: _api(token, urlopen, endpoint, params)
        payload = _execute(raw_request, api, config, export_path, gateway_path)
        _emit(payload)
        return 0
    except DiscordReadProviderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Discord read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
