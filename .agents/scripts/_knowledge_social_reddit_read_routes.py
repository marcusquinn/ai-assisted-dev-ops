#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Allowlisted PRAW read routes and bounded page response construction."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable, Iterable

from _knowledge_social_reddit_read_contract import (
    FULLNAME,
    OPAQUE_ID,
    RedditReadProviderError,
    exact_keys,
    identity_value,
    observed_at,
    optional_fullname,
)
from _knowledge_social_reddit_read_serialize import serialize

MAX_SNAPSHOT_ITEMS = 1000
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


@dataclass(frozen=True)
class ProviderPageRequest:
    """Validated request fields for one bounded provider page."""

    stream: str
    account_id: str
    after: str | None
    stop_at: str | None
    limit: int


@dataclass(frozen=True)
class ListingResult:
    """Serialized listing values and watermark progress."""

    data: list[dict[str, Any]]
    reached: bool
    newest: str | None


ListingRoute = Callable[[Any, Any, dict[str, Any]], Iterable[Any]]
SnapshotRoute = Callable[[Any], list[Any]]


def _authored_submissions(
    _client: Any, selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return selected_user.submissions.new(**kwargs)


def _authored_comments(
    _client: Any, selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return selected_user.comments.new(**kwargs)


def _mentions(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.inbox.mentions(**kwargs)


def _comment_replies(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.inbox.comment_replies(**kwargs)


def _submission_replies(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.inbox.submission_replies(**kwargs)


def _inbox_messages(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.inbox.messages(**kwargs)


def _sent_messages(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.inbox.sent(**kwargs)


def _saved(
    _client: Any, selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return selected_user.saved(**kwargs)


def _upvoted(
    _client: Any, selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return selected_user.upvoted(**kwargs)


def _downvoted(
    _client: Any, selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return selected_user.downvoted(**kwargs)


def _hidden(
    _client: Any, selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return selected_user.hidden(**kwargs)


def _subscribed_subreddits(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.user.subreddits(**kwargs)


def _moderated_subreddits(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.user.moderator_subreddits(**kwargs)


def _contributor_subreddits(
    client: Any, _selected_user: Any, kwargs: dict[str, Any]
) -> Iterable[Any]:
    return client.user.contributor_subreddits(**kwargs)


LISTING_ROUTES: dict[str, ListingRoute] = {
    "authored_submissions": _authored_submissions,
    "authored_comments": _authored_comments,
    "mentions": _mentions,
    "comment_replies": _comment_replies,
    "submission_replies": _submission_replies,
    "inbox_messages": _inbox_messages,
    "sent_messages": _sent_messages,
    "saved": _saved,
    "upvoted": _upvoted,
    "downvoted": _downvoted,
    "hidden": _hidden,
    "subscribed_subreddits": _subscribed_subreddits,
    "moderated_subreddits": _moderated_subreddits,
    "contributor_subreddits": _contributor_subreddits,
}


def _listing_generator(
    client: Any, selected_user: Any, request: ProviderPageRequest
) -> Iterable[Any]:
    route = LISTING_ROUTES.get(request.stream)
    if route is None:
        raise RedditReadProviderError("Reddit read stream is unsupported")
    params = {"after": request.after} if request.after is not None else {}
    kwargs = {
        "limit": request.limit,
        "params": params,
        "request_limit": request.limit,
    }
    return route(client, selected_user, kwargs)


def _listing_items(
    generator: Iterable[Any], selected: dict[str, str], stop_at: str | None
) -> ListingResult:
    data: list[dict[str, Any]] = []
    reached = False
    newest: str | None = None
    for value in generator:
        record = serialize(value, selected)
        item_fullname = record.get("fullname")
        if (
            not isinstance(item_fullname, str)
            or FULLNAME.fullmatch(item_fullname) is None
        ):
            raise RedditReadProviderError("Reddit listing item has no stable fullname")
        if stop_at is not None and item_fullname == stop_at:
            reached = True
            break
        if newest is None:
            newest = item_fullname
        data.append(record)
    return ListingResult(data, reached, newest)


def _next_after(
    generator: Iterable[Any], previous: str | None, reached: bool
) -> str | None:
    next_after = None
    if not reached:
        generator_params = getattr(generator, "params", None)
        if not isinstance(generator_params, dict):
            raise RedditReadProviderError("PRAW listing checkpoint is unavailable")
        candidate = generator_params.get("after")
        if candidate is not None and candidate != previous:
            if (
                not isinstance(candidate, str)
                or FULLNAME.fullmatch(candidate) is None
            ):
                raise RedditReadProviderError("PRAW listing checkpoint is invalid")
            next_after = candidate
    return next_after


def _listing_page(
    client: Any,
    selected_user: Any,
    selected: dict[str, str],
    request: ProviderPageRequest,
) -> dict[str, Any]:
    generator = _listing_generator(client, selected_user, request)
    result = _listing_items(generator, selected, request.stop_at)
    next_after = _next_after(generator, request.after, result.reached)
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": result.data,
        "meta": {
            "next_after": next_after,
            "newest_fullname": result.newest,
            "reached_watermark": result.reached,
            "complete": result.reached or next_after is None,
            "snapshot": False,
        },
    }


def _multireddits(client: Any) -> list[Any]:
    return client.user.multireddits()


def _friends(client: Any) -> list[Any]:
    return client.user.friends()


def _blocked(client: Any) -> list[Any]:
    return client.user.blocked()


def _trusted(client: Any) -> list[Any]:
    return client.user.trusted()


SNAPSHOT_ROUTES: dict[str, SnapshotRoute] = {
    "multireddits": _multireddits,
    "friends": _friends,
    "blocked": _blocked,
    "trusted": _trusted,
}


def _snapshot_values(client: Any, stream: str) -> list[Any]:
    route = SNAPSHOT_ROUTES.get(stream)
    if route is None:
        raise RedditReadProviderError("Reddit read stream is unsupported")
    values = route(client)
    if not isinstance(values, list):
        raise RedditReadProviderError("Reddit snapshot response must be a list")
    return values


def _snapshot_page(
    client: Any, stream: str, selected: dict[str, str]
) -> dict[str, Any]:
    data = [serialize(value, selected) for value in _snapshot_values(client, stream)]
    item_count = len(data) + sum(
        len(record.get("subreddits", [])) for record in data
    )
    if item_count > MAX_SNAPSHOT_ITEMS:
        raise RedditReadProviderError("Reddit snapshot exceeds the safety limit")
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": data,
        "meta": {
            "next_after": None,
            "newest_fullname": None,
            "reached_watermark": False,
            "complete": True,
            "snapshot": True,
        },
    }


def _page_request(request: dict[str, Any]) -> ProviderPageRequest:
    exact_keys(
        request,
        {"action", "stream", "account_id", "after", "stop_at", "limit"},
    )
    stream = request.get("stream")
    account_id = request.get("account_id")
    limit = request.get("limit")
    if (
        not isinstance(stream, str)
        or stream not in LISTING_STREAMS | SNAPSHOT_STREAMS
    ):
        raise RedditReadProviderError("Reddit read stream is unsupported")
    if not isinstance(account_id, str) or OPAQUE_ID.fullmatch(account_id) is None:
        raise RedditReadProviderError("Reddit read account ID is invalid")
    if (
        isinstance(limit, bool)
        or not isinstance(limit, int)
        or not 1 <= limit <= 100
    ):
        raise RedditReadProviderError("Reddit read limit must be between 1 and 100")
    return ProviderPageRequest(
        stream,
        account_id,
        optional_fullname(request.get("after")),
        optional_fullname(request.get("stop_at")),
        limit,
    )


def page(client: Any, raw_request: dict[str, Any]) -> dict[str, Any]:
    """Execute one validated listing or snapshot read against the selected account."""
    request = _page_request(raw_request)
    selected_user = client.user.me()
    selected = identity_value(selected_user)
    if selected["id"] != request.account_id:
        raise RedditReadProviderError(
            "selected Reddit account does not match the configured connection"
        )
    if request.stream in LISTING_STREAMS:
        payload = _listing_page(client, selected_user, selected, request)
    else:
        if request.after is not None or request.stop_at is not None:
            raise RedditReadProviderError("Reddit snapshot cannot accept a cursor")
        payload = _snapshot_page(client, request.stream, selected)
    return payload
