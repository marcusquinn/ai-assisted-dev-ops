#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded GET-only public Hacker News Firebase API reader subprocess."""

from __future__ import annotations

import argparse
import json
import sys
from typing import Any

from _knowledge_social_hacker_news import (
    PageRequest,
    parse_page_request,
)
from _knowledge_social_hacker_news_contract import (
    ApiResult,
    HackerNewsReadProviderError,
    MAX_ITEM_RESPONSE_BYTES,
    MAX_USER_RESPONSE_BYTES,
    item_value,
    observed_at,
    request_object,
    terminal_payload,
    user_value,
)
from _knowledge_social_hacker_news_http import Opener, _http_exports, api
from _knowledge_social_hacker_news_identity import (
    HackerNewsAdapterError,
    selector_id,
    username,
)

MAX_REQUEST_BYTES = 64 * 1024
MAX_OUTPUT_BYTES = MAX_USER_RESPONSE_BYTES + MAX_ITEM_RESPONSE_BYTES + 256 * 1024


def _profile(profile: str) -> None:
    if profile != "public":
        raise HackerNewsReadProviderError(
            "Hacker News profile must be the credential-free public profile"
        )


def _identity(opener: Opener, expected_username: str) -> dict[str, Any]:
    selected = username(expected_username)
    result = api(opener, "user", selected)
    if result.status != 200:
        return terminal_payload(result)
    data = user_value(result.payload, selected)
    data["response_bytes"] = result.response_bytes
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": data,
    }


def _verify_selector(request: PageRequest, identity: dict[str, Any]) -> None:
    if (
        identity.get("username") != request.username
        or identity.get("id") != request.selector_id
        or selector_id(request.username) != request.selector_id
    ):
        raise HackerNewsReadProviderError(
            "Hacker News public selector changed during collection"
        )


def _page(opener: Opener, request: PageRequest) -> dict[str, Any]:
    identity = _identity(opener, request.username)
    if identity.get("status") != 200:
        return identity
    data = identity.get("data")
    if not isinstance(data, dict):
        raise HackerNewsReadProviderError(
            "Hacker News public selector response is invalid"
        )
    _verify_selector(request, data)
    user_bytes = data.get("response_bytes")
    if isinstance(user_bytes, bool) or not isinstance(user_bytes, int) or user_bytes < 0:
        raise HackerNewsReadProviderError(
            "Hacker News public selector byte count is invalid"
        )
    current_item = request.item_id
    if data.get("availability") == "missing" and current_item is not None:
        return terminal_payload(ApiResult(404, None, user_bytes))
    if current_item is None:
        record = None
        item_bytes = 0
        item_state = "empty"
    else:
        result = api(opener, "item", current_item)
        if result.status != 200:
            terminal = terminal_payload(result)
            terminal["response_bytes"] = user_bytes + result.response_bytes
            return terminal
        record = item_value(result.payload, current_item, request.username)
        item_bytes = result.response_bytes
        item_state = record["state"]
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": [] if record is None else [record],
        "meta": {
            "stream": request.stream,
            "username": request.username,
            "selector_id": request.selector_id,
            "snapshot_sha256": request.snapshot_sha256,
            "position": request.position,
            "total": len(request.items),
            "item_id": current_item,
            "item_state": item_state,
            "response_bytes": user_bytes + item_bytes,
            "public_selector": True,
        },
    }


def _dispatch(request: dict[str, Any], opener: Opener) -> dict[str, Any]:
    action = request.get("action")
    if action == "identity":
        if set(request) != {"action", "account_id"}:
            raise HackerNewsReadProviderError(
                "Hacker News identity request shape is invalid"
            )
        return _identity(opener, username(request.get("account_id")))
    if action != "page":
        raise HackerNewsReadProviderError("Hacker News read action is unsupported")
    return _page(opener, parse_page_request(request))


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_OUTPUT_BYTES:
        raise HackerNewsReadProviderError(
            "Hacker News read response exceeds the safety limit"
        )
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        _profile(args.profile)
        request = request_object(
            sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1), MAX_REQUEST_BYTES
        )
        _emit(_dispatch(request, _http_exports()))
        return 0
    except (HackerNewsReadProviderError, HackerNewsAdapterError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Hacker News public read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
