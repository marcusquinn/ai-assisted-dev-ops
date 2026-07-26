#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Privacy-safe PRAW subprocess boundary for approved Reddit operations."""

from __future__ import annotations

import argparse
import importlib
import importlib.metadata
import json
import os
import re
import sys
from typing import Any

MAX_REQUEST_BYTES = 32 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
TARGET_FULLNAME = re.compile(r"^(t1|t3)_([A-Za-z0-9]+)$")
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
WRITE_ACTIONS = ("post", "reply", "like", "bookmark")
REQUIRED_CREDENTIALS = (
    "CLIENT_ID",
    "CLIENT_SECRET",
    "USERNAME",
    "PASSWORD",
    "USER_AGENT",
)


class RedditProviderError(RuntimeError):
    """Raised for a privacy-safe local Reddit provider failure."""


def _profile_prefix(profile: str) -> str:
    if PROFILE_NAME.fullmatch(profile) is None:
        raise RedditProviderError("Reddit auth profile name is invalid")
    return f"REDDIT_{profile.upper()}"


def _credentials(profile: str) -> dict[str, str]:
    prefix = _profile_prefix(profile)
    credentials = {
        field.lower(): os.environ.get(f"{prefix}_{field}", "")
        for field in REQUIRED_CREDENTIALS
    }
    if any(not value for value in credentials.values()):
        raise RedditProviderError("Reddit auth profile credentials are incomplete")
    return credentials


def _praw_factory() -> Any:
    try:
        praw = importlib.import_module("praw")
    except ImportError as error:
        raise RedditProviderError(
            "PRAW is unavailable; install it outside the agent session"
        ) from error
    factory = getattr(praw, "Reddit", None)
    version = getattr(praw, "__version__", None)
    if not isinstance(version, str) or not version:
        try:
            version = importlib.metadata.version("praw")
        except importlib.metadata.PackageNotFoundError as error:
            raise RedditProviderError("PRAW version metadata is unavailable") from error
    if not callable(factory):
        raise RedditProviderError("PRAW does not export the required Reddit client")
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
        raise RedditProviderError("Reddit provider request exceeds the safety limit")
    try:
        request = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise RedditProviderError("Reddit provider request is not valid JSON") from error
    if not isinstance(request, dict):
        raise RedditProviderError("Reddit provider request root must be an object")
    return request


def _exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise RedditProviderError("Reddit provider request has an invalid action shape")


def _text(request: dict[str, Any], field: str) -> str:
    value = request.get(field)
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise RedditProviderError("Reddit provider request has invalid text")
    return value


def _target(client: Any, fullname: str) -> Any:
    match = TARGET_FULLNAME.fullmatch(fullname)
    if match is None:
        raise RedditProviderError("Reddit target fullname is invalid")
    kind, remote_id = match.groups()
    if kind == "t1":
        return client.comment(remote_id)
    return client.submission(id=remote_id)


def _fullname(value: Any, prefix: str) -> str:
    fullname = getattr(value, "fullname", None)
    if isinstance(fullname, str) and OPAQUE_ID.fullmatch(fullname):
        return fullname
    remote_id = getattr(value, "id", None)
    if not isinstance(remote_id, str) or not remote_id:
        raise RedditProviderError("Reddit response has no stable remote ID")
    fullname = f"{prefix}_{remote_id}"
    if OPAQUE_ID.fullmatch(fullname) is None:
        raise RedditProviderError("Reddit response remote ID is invalid")
    return fullname


def _identity(client: Any, request: dict[str, Any]) -> str:
    _exact_keys(request, {"action"})
    identity = client.user.me()
    remote_id = getattr(identity, "id", None)
    if not isinstance(remote_id, str) or OPAQUE_ID.fullmatch(remote_id) is None:
        raise RedditProviderError("Reddit identity has no stable account ID")
    return remote_id


def _write(client: Any, request: dict[str, Any]) -> str:
    action = request.get("action")
    if action == "post":
        _exact_keys(request, {"action", "destination", "payload", "subject"})
        result = client.subreddit(_text(request, "destination")).submit(
            _text(request, "subject"), selftext=_text(request, "payload")
        )
        return _fullname(result, "t3")
    if action == "reply":
        _exact_keys(request, {"action", "payload", "target"})
        result = _target(client, _text(request, "target")).reply(
            _text(request, "payload")
        )
        return _fullname(result, "t1")
    if action in ("like", "bookmark"):
        _exact_keys(request, {"action", "target"})
        target = _target(client, _text(request, "target"))
        if action == "like":
            target.upvote()
        else:
            target.save()
        return _text(request, "target")
    raise RedditProviderError("Reddit provider action is unsupported")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--confirm-write", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        request = _request()
        action = request.get("action")
        if not isinstance(action, str):
            raise RedditProviderError("Reddit provider action is missing")
        if action in WRITE_ACTIONS and not args.confirm_write:
            raise RedditProviderError("Reddit writes require explicit confirmation")
        client = _client(args.profile)
        remote_id = (
            _identity(client, request)
            if action == "identity"
            else _write(client, request)
        )
        print(json.dumps({"data": {"id": remote_id}}, sort_keys=True))
        return 0
    except RedditProviderError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    except Exception:  # noqa: BLE001 - intentionally redact provider internals
        print("ERROR: Reddit provider request failed", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
