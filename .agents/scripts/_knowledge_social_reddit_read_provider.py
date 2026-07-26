#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded read-only PRAW subprocess for Reddit account collection."""

from __future__ import annotations

import argparse
import importlib
import importlib.metadata
import inspect
import json
import math
import os
import re
import sys
import time
from typing import Any

from _knowledge_social_reddit_read_contract import (
    RedditReadProviderError,
    exact_keys,
    identity_value,
    observed_at,
)
from _knowledge_social_reddit_read_routes import page as read_page

MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
REQUIRED_CREDENTIALS = (
    "CLIENT_ID",
    "CLIENT_SECRET",
    "USERNAME",
    "PASSWORD",
    "USER_AGENT",
)


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise RedditReadProviderError("Reddit auth profile name is invalid")
    return f"REDDIT_{profile.upper()}"


def _credentials(profile: str) -> dict[str, str]:
    prefix = _profile_prefix(profile)
    credentials = {
        field.lower(): os.environ.get(f"{prefix}_{field}", "")
        for field in REQUIRED_CREDENTIALS
    }
    if any(not value for value in credentials.values()):
        raise RedditReadProviderError("Reddit auth profile credentials are incomplete")
    return credentials


def _praw_module() -> Any:
    try:
        praw = importlib.import_module("praw")
    except ImportError as error:
        raise RedditReadProviderError(
            "PRAW is unavailable; install it outside the agent session"
        ) from error
    return praw


def _praw_version(praw: Any) -> str:
    version = getattr(praw, "__version__", None)
    if not isinstance(version, str) or not version:
        try:
            version = importlib.metadata.version("praw")
        except importlib.metadata.PackageNotFoundError as error:
            raise RedditReadProviderError("PRAW version metadata is unavailable") from error
    return version


def _validate_listing_generator() -> None:
    try:
        module = importlib.import_module("praw.models.listing.generator")
        generator = getattr(module, "ListingGenerator")
        parameters = inspect.signature(generator).parameters
    except (AttributeError, ImportError, TypeError, ValueError) as error:
        raise RedditReadProviderError(
            "PRAW listing generator metadata is unavailable"
        ) from error
    if not {"limit", "params", "request_limit"} <= set(parameters):
        raise RedditReadProviderError("PRAW listing generator is incompatible")


def _praw_factory() -> Any:
    praw = _praw_module()
    factory = getattr(praw, "Reddit", None)
    if not callable(factory):
        raise RedditReadProviderError("PRAW does not export the required Reddit client")
    if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        version = _praw_version(praw)
        if version.split(".", 1)[0] != "8":
            raise RedditReadProviderError("PRAW major version 8 is required")
        _validate_listing_generator()
    return factory


def _client(profile: str) -> Any:
    credentials = _credentials(profile)
    return _praw_factory()(
        client_id=credentials["client_id"],
        client_secret=credentials["client_secret"],
        username=credentials["username"],
        password=credentials["password"],
        user_agent=credentials["user_agent"],
    )


def _request() -> dict[str, Any]:
    payload = sys.stdin.buffer.read(MAX_REQUEST_BYTES + 1)
    if len(payload) > MAX_REQUEST_BYTES:
        raise RedditReadProviderError("Reddit read request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RedditReadProviderError("Reddit read request is not valid JSON") from error
    if not isinstance(request, dict):
        raise RedditReadProviderError("Reddit read request root must be an object")
    return request


def _identity(client: Any) -> dict[str, str]:
    return identity_value(client.user.me())


def _terminal_status(error: Exception) -> int | None:
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    if isinstance(status, bool) or not isinstance(status, int) or not 400 <= status <= 599:
        return None
    return status


def _retry_epoch(error: Exception) -> int | None:
    retry_after = getattr(error, "retry_after", None)
    try:
        seconds = float(retry_after) if retry_after is not None else None
    except (TypeError, ValueError):
        seconds = None
    if seconds is not None and math.isfinite(seconds) and seconds >= 0:
        return int(time.time() + math.ceil(seconds))
    return None


def _terminal_payload(error: Exception) -> dict[str, Any] | None:
    status = _terminal_status(error)
    if status is None:
        return None
    payload: dict[str, Any] = {"status": status, "observed_at": observed_at()}
    retry_after = _retry_epoch(error)
    if retry_after is not None:
        payload["retry_after"] = retry_after
    return payload


def _emit(payload: dict[str, Any]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, sort_keys=True)
    if len(encoded.encode("utf-8")) > MAX_RESPONSE_BYTES:
        raise RedditReadProviderError("Reddit read response exceeds the safety limit")
    print(encoded)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = _request()
        action = request.get("action")
        if action not in ("identity", "page"):
            raise RedditReadProviderError("Reddit read action is unsupported")
        if action == "identity":
            exact_keys(request, {"action"})
        client = _client(args.profile)
        payload = (
            {"status": 200, "observed_at": observed_at(), "data": _identity(client)}
            if action == "identity"
            else read_page(client, request)
        )
        _emit(payload)
        return 0
    except RedditReadProviderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception as error:  # noqa: BLE001 - redact all provider internals
        payload = _terminal_payload(error)
        if payload is not None:
            _emit(payload)
            return 0
        print("ERROR: Reddit read provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
