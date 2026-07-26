#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Serialize already-loaded PRAW values into a bounded plain-data contract."""

from __future__ import annotations

import hashlib
from typing import Any

from _knowledge_social_reddit_read_contract import (
    RedditReadProviderError,
    attribute,
    boolean,
    fullname,
    integer,
    number,
    optional_text,
)


def _redditor_ref(value: Any, selected: dict[str, str]) -> dict[str, Any] | None:
    if value is None:
        return None
    username = value if isinstance(value, str) else attribute(value, "name")
    username = optional_text(username, "account name")
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
    display_name = optional_text(attribute(value, "display_name"), "subreddit name")
    if not display_name:
        display_name = optional_text(str(value), "subreddit name")
    if not display_name:
        raise RedditReadProviderError("Reddit subreddit has no stable name")
    digest = hashlib.sha256(display_name.casefold().encode("utf-8")).hexdigest()
    remote_id = f"subreddit_{digest}"
    provider_id = attribute(value, "id")
    provider_fullname = (
        f"t5_{provider_id}"
        if isinstance(provider_id, str) and provider_id
        else remote_id
    )
    return {
        "kind": "subreddit",
        "fullname": provider_fullname,
        "remote_id": remote_id,
        "display_name": display_name,
        "title": optional_text(attribute(value, "title"), "subreddit title"),
        "subscribers": integer(
            attribute(value, "subscribers"), "subreddit subscribers"
        ),
        "over18": boolean(attribute(value, "over18"), "subreddit over18"),
        "url": optional_text(attribute(value, "url"), "subreddit URL"),
    }


def _submission(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    return {
        "kind": "submission",
        "fullname": fullname(value, "t3"),
        "author": _redditor_ref(attribute(value, "author"), selected),
        "subreddit": _subreddit_ref(attribute(value, "subreddit")),
        "title": optional_text(attribute(value, "title"), "submission title"),
        "selftext": optional_text(attribute(value, "selftext"), "submission body"),
        "created_utc": number(
            attribute(value, "created_utc"), "submission timestamp"
        ),
        "score": integer(attribute(value, "score"), "submission score"),
        "permalink": optional_text(
            attribute(value, "permalink"), "submission permalink"
        ),
        "url": optional_text(attribute(value, "url"), "submission URL"),
        "over_18": boolean(attribute(value, "over_18"), "submission over_18"),
        "is_self": boolean(attribute(value, "is_self"), "submission is_self"),
        "link_flair_text": optional_text(
            attribute(value, "link_flair_text"), "submission flair"
        ),
        "num_comments": integer(
            attribute(value, "num_comments"), "submission comment count"
        ),
    }


def _comment(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    return {
        "kind": "comment",
        "fullname": fullname(value, "t1"),
        "author": _redditor_ref(attribute(value, "author"), selected),
        "subreddit": _subreddit_ref(attribute(value, "subreddit")),
        "body": optional_text(attribute(value, "body"), "comment body"),
        "created_utc": number(attribute(value, "created_utc"), "comment timestamp"),
        "score": integer(attribute(value, "score"), "comment score"),
        "permalink": optional_text(
            attribute(value, "permalink"), "comment permalink"
        ),
        "parent_id": optional_text(
            attribute(value, "parent_id"), "comment parent ID"
        ),
        "link_id": optional_text(attribute(value, "link_id"), "comment link ID"),
        "controversiality": integer(
            attribute(value, "controversiality"), "comment controversiality"
        ),
    }


def _message(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    destination = attribute(value, "dest")
    if destination is not None and not isinstance(destination, str):
        destination = attribute(destination, "name")
    return {
        "kind": "message",
        "fullname": fullname(value, "t4"),
        "author": _redditor_ref(attribute(value, "author"), selected),
        "body": optional_text(attribute(value, "body"), "message body"),
        "subject": optional_text(attribute(value, "subject"), "message subject"),
        "created_utc": number(attribute(value, "created_utc"), "message timestamp"),
        "dest": optional_text(destination, "message destination"),
        "context": optional_text(attribute(value, "context"), "message context"),
        "parent_id": optional_text(
            attribute(value, "parent_id"), "message parent ID"
        ),
        "first_message_name": optional_text(
            attribute(value, "first_message_name"), "message thread ID"
        ),
        "was_comment": boolean(attribute(value, "was_comment"), "message kind"),
    }


def _redditor(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    reference = _redditor_ref(value, selected)
    if reference is None:
        raise RedditReadProviderError("Reddit relationship has no account identity")
    return {
        "kind": "redditor",
        **reference,
        "relationship_utc": number(
            attribute(value, "date"), "relationship timestamp"
        ),
    }


def _subreddit(value: Any) -> dict[str, Any]:
    reference = _subreddit_ref(value)
    if reference is None:
        raise RedditReadProviderError("Reddit relationship has no subreddit identity")
    return reference


def _multireddit(value: Any) -> dict[str, Any]:
    path = optional_text(attribute(value, "path"), "multireddit path")
    display_name = optional_text(
        attribute(value, "display_name"), "multireddit display name"
    )
    if not path or not display_name:
        raise RedditReadProviderError("Reddit multireddit has no stable identity")
    remote_id = f"multi_{hashlib.sha256(path.encode('utf-8')).hexdigest()}"
    members = attribute(value, "subreddits")
    if not isinstance(members, list):
        raise RedditReadProviderError("Reddit multireddit memberships are invalid")
    return {
        "kind": "multireddit",
        "remote_id": remote_id,
        "display_name": display_name,
        "path": path,
        "description_md": optional_text(
            attribute(value, "description_md"), "multireddit description"
        ),
        "visibility": optional_text(
            attribute(value, "visibility"), "multireddit visibility"
        ),
        "subreddits": [_subreddit(member) for member in members],
    }


def serialize(value: Any, selected: dict[str, str]) -> dict[str, Any]:
    """Serialize one allowlisted PRAW model without triggering lazy attributes."""
    kind = type(value).__name__
    if kind == "Submission":
        record = _submission(value, selected)
    elif kind == "Comment":
        record = _comment(value, selected)
    elif kind == "Message":
        record = _message(value, selected)
    elif kind == "Subreddit":
        record = _subreddit(value)
    elif kind == "Redditor":
        record = _redditor(value, selected)
    elif kind in ("Multireddit", "MultiReddit"):
        record = _multireddit(value)
    else:
        raise RedditReadProviderError(
            "Reddit response contains an unsupported item type"
        )
    return record
