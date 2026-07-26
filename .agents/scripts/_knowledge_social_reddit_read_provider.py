#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded read-only PRAW subprocess for Reddit account collection."""

from __future__ import annotations

import argparse
import hashlib
import importlib
import importlib.metadata
import inspect
import json
import math
import os
import re
import sys
import time
from datetime import UTC, datetime
from typing import Any, Iterable

MAX_REQUEST_BYTES = 32 * 1024
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
MAX_SNAPSHOT_ITEMS = 1000
MAX_TEXT_BYTES = 256 * 1024
PROFILE_NAME = re.compile(r"^[a-z0-9][a-z0-9_]{0,63}$")
FULLNAME = re.compile(r"^t[1-9]_[A-Za-z0-9]+$")
OPAQUE_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
REQUIRED_CREDENTIALS = (
    "CLIENT_ID",
    "CLIENT_SECRET",
    "USERNAME",
    "PASSWORD",
    "USER_AGENT",
)
LISTING_STREAMS = {
    "authored_submissions",
    "authored_comments",
    "mentions",
    "comment_replies",
    "submission_replies",
    "inbox_messages",
    "sent_messages",
    "saved",
    "upvoted",
    "downvoted",
    "hidden",
    "subscribed_subreddits",
    "moderated_subreddits",
    "contributor_subreddits",
}
SNAPSHOT_STREAMS = {"multireddits", "friends", "blocked", "trusted"}


class RedditReadProviderError(RuntimeError):
    """Raised for a privacy-safe local Reddit read failure."""


def _observed_at() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


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


def _praw_factory() -> Any:
    try:
        praw = importlib.import_module("praw")
    except ImportError as error:
        raise RedditReadProviderError(
            "PRAW is unavailable; install it outside the agent session"
        ) from error
    factory = getattr(praw, "Reddit", None)
    version = getattr(praw, "__version__", None)
    if not isinstance(version, str) or not version:
        try:
            version = importlib.metadata.version("praw")
        except importlib.metadata.PackageNotFoundError as error:
            raise RedditReadProviderError("PRAW version metadata is unavailable") from error
    if not callable(factory):
        raise RedditReadProviderError("PRAW does not export the required Reddit client")
    if os.environ.get("AIDEVOPS_TEST_MODE") != "1":
        if version.split(".", 1)[0] != "8":
            raise RedditReadProviderError("PRAW major version 8 is required")
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


def _exact_keys(request: dict[str, Any], expected: set[str]) -> None:
    if set(request) != expected:
        raise RedditReadProviderError("Reddit read request has an invalid action shape")


def _identity_value(identity: Any) -> dict[str, str]:
    remote_id = getattr(identity, "id", None)
    username = getattr(identity, "name", None)
    if not isinstance(remote_id, str) or OPAQUE_ID.fullmatch(remote_id) is None:
        raise RedditReadProviderError("Reddit identity has no stable account ID")
    if not isinstance(username, str) or not username:
        raise RedditReadProviderError("Reddit identity has no account name")
    return {"id": remote_id, "username": username}


def _identity(client: Any) -> dict[str, str]:
    return _identity_value(client.user.me())


def _optional_text(value: Any, field: str) -> str | None:
    if value is None:
        return None
    if not isinstance(value, str) or "\x00" in value:
        raise RedditReadProviderError(f"Reddit {field} must be text")
    if len(value.encode("utf-8")) > MAX_TEXT_BYTES:
        raise RedditReadProviderError(f"Reddit {field} exceeds the safety limit")
    return value


def _attribute(value: Any, name: str) -> Any:
    try:
        attributes = object.__getattribute__(value, "__dict__")
    except (AttributeError, TypeError) as error:
        raise RedditReadProviderError("Reddit response attribute is unavailable") from error
    if not isinstance(attributes, dict):
        raise RedditReadProviderError("Reddit response attributes are invalid")
    return attributes.get(name)


def _number(value: Any, field: str) -> int | float | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise RedditReadProviderError(f"Reddit {field} must be numeric")
    if not math.isfinite(float(value)):
        raise RedditReadProviderError(f"Reddit {field} must be finite")
    return value


def _integer(value: Any, field: str) -> int | None:
    if value is None:
        return None
    if isinstance(value, bool) or not isinstance(value, int):
        raise RedditReadProviderError(f"Reddit {field} must be an integer")
    return value


def _boolean(value: Any, field: str) -> bool | None:
    if value is None:
        return None
    if not isinstance(value, bool):
        raise RedditReadProviderError(f"Reddit {field} must be boolean")
    return value


def _fullname(value: Any, prefix: str) -> str:
    for field in ("fullname", "name"):
        candidate = _attribute(value, field)
        if isinstance(candidate, str) and FULLNAME.fullmatch(candidate):
            return candidate
    remote_id = _attribute(value, "id")
    candidate = f"{prefix}_{remote_id}" if isinstance(remote_id, str) else ""
    if FULLNAME.fullmatch(candidate) is None:
        raise RedditReadProviderError("Reddit response has no stable fullname")
    return candidate


def _redditor_ref(value: Any, selected: dict[str, str]) -> dict[str, Any] | None:
    if value is None:
        return None
    username = value if isinstance(value, str) else _attribute(value, "name")
    username = _optional_text(username, "account name")
    if not username:
        return None
    if username.casefold() == selected["username"].casefold():
        remote_id = selected["id"]
    else:
        digest = hashlib.sha256(username.casefold().encode("utf-8")).hexdigest()
        remote_id = f"usr_{digest}"
    return {"remote_id": remote_id, "name": username}


def _subreddit_ref(value: Any) -> dict[str, Any] | None:
    if value is None:
        return None
    display_name = _optional_text(_attribute(value, "display_name"), "subreddit name")
    if not display_name:
        display_name = _optional_text(str(value), "subreddit name")
    if not display_name:
        raise RedditReadProviderError("Reddit subreddit has no stable name")
    digest = hashlib.sha256(display_name.casefold().encode("utf-8")).hexdigest()
    remote_id = f"subreddit_{digest}"
    provider_id = _attribute(value, "id")
    fullname = (
        f"t5_{provider_id}"
        if isinstance(provider_id, str) and provider_id
        else remote_id
    )
    return {
        "kind": "subreddit",
        "fullname": fullname,
        "remote_id": remote_id,
        "display_name": display_name,
        "title": _optional_text(_attribute(value, "title"), "subreddit title"),
        "subscribers": _integer(
            _attribute(value, "subscribers"), "subreddit subscribers"
        ),
        "over18": _boolean(_attribute(value, "over18"), "subreddit over18"),
        "url": _optional_text(_attribute(value, "url"), "subreddit URL"),
    }


def _submission(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    return {
        "kind": "submission",
        "fullname": _fullname(value, "t3"),
        "author": _redditor_ref(_attribute(value, "author"), selected),
        "subreddit": _subreddit_ref(_attribute(value, "subreddit")),
        "title": _optional_text(_attribute(value, "title"), "submission title"),
        "selftext": _optional_text(_attribute(value, "selftext"), "submission body"),
        "created_utc": _number(
            _attribute(value, "created_utc"), "submission timestamp"
        ),
        "score": _integer(_attribute(value, "score"), "submission score"),
        "permalink": _optional_text(
            _attribute(value, "permalink"), "submission permalink"
        ),
        "url": _optional_text(_attribute(value, "url"), "submission URL"),
        "over_18": _boolean(_attribute(value, "over_18"), "submission over_18"),
        "is_self": _boolean(_attribute(value, "is_self"), "submission is_self"),
        "link_flair_text": _optional_text(
            _attribute(value, "link_flair_text"), "submission flair"
        ),
        "num_comments": _integer(
            _attribute(value, "num_comments"), "submission comment count"
        ),
    }


def _comment(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    return {
        "kind": "comment",
        "fullname": _fullname(value, "t1"),
        "author": _redditor_ref(_attribute(value, "author"), selected),
        "subreddit": _subreddit_ref(_attribute(value, "subreddit")),
        "body": _optional_text(_attribute(value, "body"), "comment body"),
        "created_utc": _number(_attribute(value, "created_utc"), "comment timestamp"),
        "score": _integer(_attribute(value, "score"), "comment score"),
        "permalink": _optional_text(
            _attribute(value, "permalink"), "comment permalink"
        ),
        "parent_id": _optional_text(
            _attribute(value, "parent_id"), "comment parent ID"
        ),
        "link_id": _optional_text(_attribute(value, "link_id"), "comment link ID"),
        "controversiality": _integer(
            _attribute(value, "controversiality"), "comment controversiality"
        ),
    }


def _message(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    destination = _attribute(value, "dest")
    if destination is not None and not isinstance(destination, str):
        destination = _attribute(destination, "name")
    return {
        "kind": "message",
        "fullname": _fullname(value, "t4"),
        "author": _redditor_ref(_attribute(value, "author"), selected),
        "body": _optional_text(_attribute(value, "body"), "message body"),
        "subject": _optional_text(_attribute(value, "subject"), "message subject"),
        "created_utc": _number(_attribute(value, "created_utc"), "message timestamp"),
        "dest": _optional_text(destination, "message destination"),
        "context": _optional_text(_attribute(value, "context"), "message context"),
        "parent_id": _optional_text(
            _attribute(value, "parent_id"), "message parent ID"
        ),
        "first_message_name": _optional_text(
            _attribute(value, "first_message_name"), "message thread ID"
        ),
        "was_comment": _boolean(_attribute(value, "was_comment"), "message kind"),
    }


def _redditor(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    reference = _redditor_ref(value, selected)
    if reference is None:
        raise RedditReadProviderError("Reddit relationship has no account identity")
    return {
        "kind": "redditor",
        **reference,
        "relationship_utc": _number(
            _attribute(value, "date"), "relationship timestamp"
        ),
    }


def _subreddit(value: Any) -> dict[str, Any]:
    reference = _subreddit_ref(value)
    if reference is None:
        raise RedditReadProviderError("Reddit relationship has no subreddit identity")
    return reference


def _multireddit(value: Any) -> dict[str, Any]:
    path = _optional_text(_attribute(value, "path"), "multireddit path")
    display_name = _optional_text(
        _attribute(value, "display_name"), "multireddit display name"
    )
    if not path or not display_name:
        raise RedditReadProviderError("Reddit multireddit has no stable identity")
    remote_id = f"multi_{hashlib.sha256(path.encode('utf-8')).hexdigest()}"
    members = _attribute(value, "subreddits")
    if not isinstance(members, list):
        raise RedditReadProviderError("Reddit multireddit memberships are invalid")
    return {
        "kind": "multireddit",
        "remote_id": remote_id,
        "display_name": display_name,
        "path": path,
        "description_md": _optional_text(
            _attribute(value, "description_md"), "multireddit description"
        ),
        "visibility": _optional_text(
            _attribute(value, "visibility"), "multireddit visibility"
        ),
        "subreddits": [_subreddit(member) for member in members],
    }


def _serialize(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    kind = type(value).__name__
    if kind == "Submission":
        return _submission(value, selected)
    if kind == "Comment":
        return _comment(value, selected)
    if kind == "Message":
        return _message(value, selected)
    if kind == "Subreddit":
        return _subreddit(value)
    if kind == "Redditor":
        return _redditor(value, selected)
    if kind in ("Multireddit", "MultiReddit"):
        return _multireddit(value)
    raise RedditReadProviderError("Reddit response contains an unsupported item type")


def _listing_generator(
    client: Any,
    stream: str,
    selected_user: Any,
    *,
    limit: int,
    params: dict[str, str],
) -> Iterable[Any]:
    kwargs = {"limit": limit, "params": params, "request_limit": limit}
    if stream == "authored_submissions":
        return selected_user.submissions.new(**kwargs)
    if stream == "authored_comments":
        return selected_user.comments.new(**kwargs)
    if stream == "mentions":
        return client.inbox.mentions(**kwargs)
    if stream == "comment_replies":
        return client.inbox.comment_replies(**kwargs)
    if stream == "submission_replies":
        return client.inbox.submission_replies(**kwargs)
    if stream == "inbox_messages":
        return client.inbox.messages(**kwargs)
    if stream == "sent_messages":
        return client.inbox.sent(**kwargs)
    if stream == "saved":
        return selected_user.saved(**kwargs)
    if stream == "upvoted":
        return selected_user.upvoted(**kwargs)
    if stream == "downvoted":
        return selected_user.downvoted(**kwargs)
    if stream == "hidden":
        return selected_user.hidden(**kwargs)
    if stream == "subscribed_subreddits":
        return client.user.subreddits(**kwargs)
    if stream == "moderated_subreddits":
        return client.user.moderator_subreddits(**kwargs)
    if stream == "contributor_subreddits":
        return client.user.contributor_subreddits(**kwargs)
    raise RedditReadProviderError("Reddit read stream is unsupported")


def _listing_page(
    client: Any,
    stream: str,
    selected_user: Any,
    selected: dict[str, str],
    request: dict[str, Any],
) -> dict[str, Any]:
    limit = request["limit"]
    after = request["after"]
    stop_at = request["stop_at"]
    params = {"after": after} if after is not None else {}
    generator = _listing_generator(
        client, stream, selected_user, limit=limit, params=params
    )
    data: list[dict[str, Any]] = []
    reached = False
    newest: str | None = None
    for value in generator:
        record = _serialize(value, selected)
        fullname = record.get("fullname")
        if not isinstance(fullname, str) or FULLNAME.fullmatch(fullname) is None:
            raise RedditReadProviderError("Reddit listing item has no stable fullname")
        if stop_at is not None and fullname == stop_at:
            reached = True
            break
        if newest is None:
            newest = fullname
        data.append(record)
    next_after = None
    if not reached:
        generator_params = getattr(generator, "params", None)
        if not isinstance(generator_params, dict):
            raise RedditReadProviderError("PRAW listing checkpoint is unavailable")
        candidate = generator_params.get("after")
        if candidate is not None and candidate != after:
            if not isinstance(candidate, str) or FULLNAME.fullmatch(candidate) is None:
                raise RedditReadProviderError("PRAW listing checkpoint is invalid")
            next_after = candidate
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": data,
        "meta": {
            "next_after": next_after,
            "newest_fullname": newest,
            "reached_watermark": reached,
            "complete": reached or next_after is None,
            "snapshot": False,
        },
    }


def _snapshot_values(client: Any, stream: str) -> list[Any]:
    if stream == "multireddits":
        values = client.user.multireddits()
    elif stream == "friends":
        values = client.user.friends()
    elif stream == "blocked":
        values = client.user.blocked()
    elif stream == "trusted":
        values = client.user.trusted()
    else:
        raise RedditReadProviderError("Reddit read stream is unsupported")
    if not isinstance(values, list):
        raise RedditReadProviderError("Reddit snapshot response must be a list")
    return values


def _snapshot_page(
    client: Any, stream: str, selected: dict[str, str]
) -> dict[str, Any]:
    values = _snapshot_values(client, stream)
    data = [_serialize(value, selected) for value in values]
    item_count = len(data) + sum(
        len(record.get("subreddits", [])) for record in data
    )
    if item_count > MAX_SNAPSHOT_ITEMS:
        raise RedditReadProviderError("Reddit snapshot exceeds the safety limit")
    return {
        "status": 200,
        "observed_at": _observed_at(),
        "data": data,
        "meta": {
            "next_after": None,
            "newest_fullname": None,
            "reached_watermark": False,
            "complete": True,
            "snapshot": True,
        },
    }


def _page(client: Any, request: dict[str, Any]) -> dict[str, Any]:
    _exact_keys(
        request,
        {"action", "stream", "account_id", "after", "stop_at", "limit"},
    )
    stream = request.get("stream")
    account_id = request.get("account_id")
    limit = request.get("limit")
    if stream not in LISTING_STREAMS | SNAPSHOT_STREAMS:
        raise RedditReadProviderError("Reddit read stream is unsupported")
    if not isinstance(account_id, str) or OPAQUE_ID.fullmatch(account_id) is None:
        raise RedditReadProviderError("Reddit read account ID is invalid")
    if isinstance(limit, bool) or not isinstance(limit, int) or not 1 <= limit <= 100:
        raise RedditReadProviderError("Reddit read limit must be between 1 and 100")
    for field in ("after", "stop_at"):
        value = request.get(field)
        if value is not None and (
            not isinstance(value, str) or FULLNAME.fullmatch(value) is None
        ):
            raise RedditReadProviderError("Reddit read checkpoint is invalid")
    selected_user = client.user.me()
    selected = _identity_value(selected_user)
    if selected["id"] != account_id:
        raise RedditReadProviderError(
            "selected Reddit account does not match the configured connection"
        )
    if stream in LISTING_STREAMS:
        return _listing_page(
            client, stream, selected_user, selected, request
        )
    if request["after"] is not None or request["stop_at"] is not None:
        raise RedditReadProviderError("Reddit snapshot cannot accept a cursor")
    return _snapshot_page(client, stream, selected)


def _terminal_payload(error: Exception) -> dict[str, Any] | None:
    response = getattr(error, "response", None)
    status = getattr(response, "status_code", None)
    if isinstance(status, bool) or not isinstance(status, int) or not 400 <= status <= 599:
        return None
    payload: dict[str, Any] = {"status": status, "observed_at": _observed_at()}
    retry_after = getattr(error, "retry_after", None)
    try:
        seconds = float(retry_after) if retry_after is not None else None
    except (TypeError, ValueError):
        seconds = None
    if seconds is not None and math.isfinite(seconds) and seconds >= 0:
        payload["retry_after"] = int(time.time() + math.ceil(seconds))
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
            _exact_keys(request, {"action"})
        client = _client(args.profile)
        payload = (
            {"status": 200, "observed_at": _observed_at(), "data": _identity(client)}
            if action == "identity"
            else _page(client, request)
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
