#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded, redirect-free, GET-only Nextcloud Talk OCS reader subprocess."""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from functools import partial
from typing import Any

from _knowledge_social_nextcloud_talk import (
    NextcloudTalkAdapterError,
    PageRequest,
    parse_page_request,
)
from _knowledge_social_nextcloud_talk_contract import (
    ApiResult,
    NextcloudTalkReadProviderError,
    request_object,
    terminal_payload,
)
from _knowledge_social_nextcloud_talk_http import (
    MAX_RESPONSE_BYTES,
    Opener,
    ProfileConfig,
    api,
    canonical_base_url,
    http_opener,
    installation_fingerprint,
)
from _knowledge_social_nextcloud_talk_identity import identity
from _knowledge_social_nextcloud_talk_routes import page

MAX_REQUEST_BYTES = 64 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
ROOM_TOKEN = re.compile(r"^[A-Za-z0-9]{4,64}$")


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise NextcloudTalkReadProviderError("Nextcloud Talk profile name is invalid")
    return f"NEXTCLOUD_TALK_{profile.upper()}"


def _profile_value(prefix: str, suffix: str, field: str, limit: int) -> str:
    value = os.environ.get(f"{prefix}_{suffix}", "")
    if not value or "\x00" in value or len(value.encode()) > limit:
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk profile {field} is missing")
    return value


def _positive_major(value: str, field: str) -> int:
    try:
        result = int(value)
    except ValueError as error:
        raise NextcloudTalkReadProviderError(
            f"Nextcloud Talk profile {field} is invalid"
        ) from error
    if result < 1 or result > 999:
        raise NextcloudTalkReadProviderError(f"Nextcloud Talk profile {field} is invalid")
    return result


def _allowed_rooms(value: str) -> tuple[str, ...]:
    rooms = tuple(part.strip() for part in value.split(",") if part.strip())
    if (
        not rooms
        or len(rooms) > 100
        or len(set(rooms)) != len(rooms)
        or any(ROOM_TOKEN.fullmatch(room) is None for room in rooms)
    ):
        raise NextcloudTalkReadProviderError(
            "Nextcloud Talk profile room allowlist is invalid"
        )
    return rooms


def _profile(profile: str) -> ProfileConfig:
    prefix = _profile_prefix(profile)
    base_url = canonical_base_url(
        _profile_value(prefix, "BASE_URL", "base URL", 4096)
    )
    username = _profile_value(prefix, "USERNAME", "username", 512)
    app_password = _profile_value(prefix, "APP_PASSWORD", "app password", 16 * 1024)
    origin_key = _profile_value(prefix, "ORIGIN_KEY", "origin key", 16 * 1024)
    rooms = _allowed_rooms(
        _profile_value(prefix, "ALLOWED_ROOMS", "room allowlist", 16 * 1024)
    )
    server_major = _positive_major(
        _profile_value(prefix, "EXPECTED_SERVER_MAJOR", "server major", 8),
        "server major",
    )
    talk_major = _positive_major(
        _profile_value(prefix, "EXPECTED_TALK_MAJOR", "Talk major", 8),
        "Talk major",
    )
    return ProfileConfig(
        base_url,
        username,
        app_password,
        origin_key,
        installation_fingerprint(base_url, origin_key),
        rooms,
        server_major,
        talk_major,
    )


def _identity(
    config: ProfileConfig, opener: Opener, expected_selector: str
) -> dict[str, Any]:
    result = identity(partial(api, config, opener), config, expected_selector)
    if isinstance(result, ApiResult):
        return terminal_payload(result)
    return {"status": 200, "data": result, "observed_at": result.get("observed_at")}


def _verify_page(request: PageRequest, data: dict[str, Any], config: ProfileConfig) -> None:
    rooms = data.get("room_ids")
    if not isinstance(rooms, list):
        raise NextcloudTalkReadProviderError("Nextcloud Talk verified rooms are invalid")
    if request.stream not in ("capabilities", "rooms") and request.room_index >= len(rooms):
        raise NextcloudTalkReadProviderError("Nextcloud Talk room index is invalid")
    expected_room = (
        None
        if request.stream in ("capabilities", "rooms")
        else rooms[request.room_index]
    )
    bindings_match = (
        request.instance_id == config.instance_id,
        request.instance_id == data.get("instance_id"),
        request.account_id == data.get("id"),
        request.provider_account_id == data.get("provider_account_id"),
        request.room_id == expected_room,
    )
    if not all(bindings_match):
        raise NextcloudTalkReadProviderError(
            "selected Nextcloud Talk account or room does not match the profile"
        )


def _dispatch(
    request: dict[str, Any], config: ProfileConfig, opener: Opener
) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise NextcloudTalkReadProviderError("Nextcloud Talk identity request is invalid")
        expected = request.get("account_id")
        if not isinstance(expected, str):
            raise NextcloudTalkReadProviderError("Nextcloud Talk account selector is invalid")
        return _identity(config, opener, expected)
    page_request = parse_page_request(request)
    verified = _identity(config, opener, f"user_{config.username}")
    if verified.get("status") != 200:
        return verified
    data = verified.get("data")
    if not isinstance(data, dict):
        raise NextcloudTalkReadProviderError("Nextcloud Talk identity response is invalid")
    _verify_page(page_request, data, config)
    result = page(partial(api, config, opener), config, page_request, data)
    return terminal_payload(result) if isinstance(result, ApiResult) else result


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode()) > MAX_RESPONSE_BYTES:
        raise NextcloudTalkReadProviderError("Nextcloud Talk response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = request_object(sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES)
        _emit(_dispatch(request, _profile(args.profile), http_opener()))
        return 0
    except (NextcloudTalkReadProviderError, NextcloudTalkAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - redact provider and credential internals
        print("ERROR: Nextcloud Talk read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
