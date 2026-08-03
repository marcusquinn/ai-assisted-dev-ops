#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Version-neutral allowlisted Lemmy records and watermark overlap."""

from __future__ import annotations

from datetime import datetime, timedelta
from typing import Any

from _knowledge_social_lemmy import PageRequest
from _knowledge_social_lemmy_contract import (
    LemmyReadProviderError,
    object_value,
    optional_boolean,
    optional_text,
    required_text,
)
from _knowledge_social_lemmy_identity import activitypub_id, namespaced_id, positive_id


def _resource(request: PageRequest, kind: str, value: Any, field: str) -> tuple[str, str]:
    try:
        local_id = positive_id(value, field)
        return namespaced_id(request.instance_id, kind, local_id), local_id
    except RuntimeError as error:
        raise LemmyReadProviderError(str(error)) from error


def _ap_id(value: Any, field: str) -> str:
    try:
        return activitypub_id(value, field)
    except RuntimeError as error:
        raise LemmyReadProviderError(str(error)) from error


def post_record(view_value: Any, request: PageRequest, *, v4: bool) -> dict[str, Any]:
    view = object_value(view_value, "post view")
    post = object_value(view.get("post"), "post")
    creator = object_value(view.get("creator"), "post creator")
    community = object_value(view.get("community"), "post community")
    remote_id, provider_id = _resource(request, "post", post.get("id"), "post ID")
    author_id, author_provider_id = _resource(
        request, "person", creator.get("id"), "post creator ID"
    )
    if request.stream.startswith("authored_") and author_provider_id != request.provider_account_id:
        raise LemmyReadProviderError(
            "Lemmy authored post does not belong to the selected account"
        )
    community_id, _local_community_id = _resource(
        request, "community", community.get("id"), "post community ID"
    )
    published_key = "published_at" if v4 else "published"
    updated_key = "updated_at" if v4 else "updated"
    person_ap_key = "ap_id" if v4 else "actor_id"
    community_ap_key = "ap_id" if v4 else "actor_id"
    return {
        "kind": "post",
        "remote_id": remote_id,
        "provider_id": provider_id,
        "author_remote_id": author_id,
        "author_ap_id": _ap_id(creator.get(person_ap_key), "post creator ActivityPub ID"),
        "community_remote_id": community_id,
        "title": required_text(post.get("name"), "post title"),
        "content": optional_text(post.get("body"), "post body"),
        "created_at": required_text(post.get(published_key), "post timestamp"),
        "updated_at": optional_text(post.get(updated_key), "post update timestamp"),
        "ap_id": _ap_id(post.get("ap_id"), "post ActivityPub ID"),
        "community_ap_id": _ap_id(
            community.get(community_ap_key), "community ActivityPub ID"
        ),
        "deleted": optional_boolean(post.get("deleted"), "post deleted flag"),
        "removed": optional_boolean(post.get("removed"), "post removed flag"),
    }


def comment_record(view_value: Any, request: PageRequest, *, v4: bool) -> dict[str, Any]:
    view = object_value(view_value, "comment view")
    comment = object_value(view.get("comment"), "comment")
    creator = object_value(view.get("creator"), "comment creator")
    post = object_value(view.get("post"), "comment post")
    community = object_value(view.get("community"), "comment community")
    remote_id, provider_id = _resource(
        request, "comment", comment.get("id"), "comment ID"
    )
    author_id, author_provider_id = _resource(
        request, "person", creator.get("id"), "comment creator ID"
    )
    if request.stream.startswith("authored_") and author_provider_id != request.provider_account_id:
        raise LemmyReadProviderError(
            "Lemmy authored comment does not belong to the selected account"
        )
    post_id, _local_post_id = _resource(request, "post", post.get("id"), "comment post ID")
    community_id, _local_community_id = _resource(
        request, "community", community.get("id"), "comment community ID"
    )
    published_key = "published_at" if v4 else "published"
    updated_key = "updated_at" if v4 else "updated"
    person_ap_key = "ap_id" if v4 else "actor_id"
    return {
        "kind": "comment",
        "remote_id": remote_id,
        "provider_id": provider_id,
        "author_remote_id": author_id,
        "author_ap_id": _ap_id(
            creator.get(person_ap_key), "comment creator ActivityPub ID"
        ),
        "post_remote_id": post_id,
        "community_remote_id": community_id,
        "content": required_text(comment.get("content"), "comment content"),
        "created_at": required_text(comment.get(published_key), "comment timestamp"),
        "updated_at": optional_text(comment.get(updated_key), "comment update timestamp"),
        "ap_id": _ap_id(comment.get("ap_id"), "comment ActivityPub ID"),
        "deleted": optional_boolean(comment.get("deleted"), "comment deleted flag"),
        "removed": optional_boolean(comment.get("removed"), "comment removed flag"),
    }


def community_record(view_value: Any, request: PageRequest, *, v4: bool) -> dict[str, Any]:
    view = object_value(view_value, "community view")
    community = object_value(view.get("community"), "community")
    if v4:
        actions = object_value(view.get("community_actions"), "community actions")
        if actions.get("follow_state") not in ("accepted", "pending", "approval_required"):
            raise LemmyReadProviderError("Lemmy community is not subscribed")
        ap_key, published_key, updated_key, summary_key = (
            "ap_id", "published_at", "updated_at", "summary"
        )
    else:
        if view.get("subscribed") not in ("Subscribed", "Pending"):
            raise LemmyReadProviderError("Lemmy community is not subscribed")
        ap_key, published_key, updated_key, summary_key = (
            "actor_id", "published", "updated", "description"
        )
    remote_id, provider_id = _resource(
        request, "community", community.get("id"), "community ID"
    )
    return {
        "kind": "community",
        "remote_id": remote_id,
        "provider_id": provider_id,
        "name": required_text(community.get("name"), "community name"),
        "title": optional_text(community.get("title"), "community title"),
        "content": optional_text(community.get(summary_key), "community summary"),
        "created_at": required_text(community.get(published_key), "community timestamp"),
        "updated_at": optional_text(community.get(updated_key), "community update timestamp"),
        "ap_id": _ap_id(community.get(ap_key), "community ActivityPub ID"),
    }


def multicommunity_record(view_value: Any, request: PageRequest) -> dict[str, Any]:
    view = object_value(view_value, "multicommunity view")
    multi = object_value(view.get("multi"), "multicommunity")
    if view.get("follow_state") not in ("accepted", "pending", "approval_required"):
        raise LemmyReadProviderError("Lemmy multicommunity is not subscribed")
    remote_id, provider_id = _resource(
        request, "multicommunity", multi.get("id"), "multicommunity ID"
    )
    return {
        "kind": "multicommunity",
        "remote_id": remote_id,
        "provider_id": provider_id,
        "name": required_text(multi.get("name"), "multicommunity name"),
        "title": optional_text(multi.get("title"), "multicommunity title"),
        "content": optional_text(multi.get("summary"), "multicommunity summary"),
        "created_at": required_text(multi.get("published_at"), "multicommunity timestamp"),
        "updated_at": optional_text(
            multi.get("updated_at"), "multicommunity update timestamp"
        ),
        "ap_id": _ap_id(multi.get("ap_id"), "multicommunity ActivityPub ID"),
    }


def notification_record(view_value: Any, request: PageRequest) -> dict[str, Any]:
    view = object_value(view_value, "notification view")
    notification = object_value(view.get("notification"), "notification")
    data = object_value(view.get("data"), "notification data")
    remote_id, provider_id = _resource(
        request, "notification", notification.get("id"), "notification ID"
    )
    _recipient_id, recipient_provider_id = _resource(
        request, "person", notification.get("recipient_id"), "notification recipient ID"
    )
    if recipient_provider_id != request.provider_account_id:
        raise LemmyReadProviderError(
            "Lemmy notification does not belong to the selected account"
        )
    actor_id, _actor_provider_id = _resource(
        request, "person", notification.get("creator_id"), "notification creator ID"
    )
    object_remote_id = None
    if notification.get("comment_id") is not None:
        object_remote_id, _object_provider_id = _resource(
            request, "comment", notification["comment_id"], "notification comment ID"
        )
    elif notification.get("post_id") is not None:
        object_remote_id, _object_provider_id = _resource(
            request, "post", notification["post_id"], "notification post ID"
        )
    data_type = required_text(data.get("type_"), "notification data type")
    if data_type in ("comment", "post", "private_message"):
        actor = object_value(data.get("creator"), "notification creator")
    elif data_type == "mod_action":
        actor_value = data.get("moderator")
        actor = (
            object_value(actor_value, "notification moderator")
            if actor_value is not None
            else None
        )
    else:
        raise LemmyReadProviderError("Lemmy notification data type is unsupported")
    return {
        "kind": "notification",
        "remote_id": remote_id,
        "provider_id": provider_id,
        "notification_type": required_text(notification.get("kind"), "notification kind"),
        "actor_remote_id": actor_id,
        "actor_ap_id": (
            _ap_id(actor.get("ap_id"), "notification actor ActivityPub ID")
            if actor is not None
            else None
        ),
        "object_remote_id": object_remote_id,
        "created_at": required_text(notification.get("published_at"), "notification timestamp"),
        "read": optional_boolean(notification.get("read"), "notification read flag"),
    }


def split_inbox_record(
    view_value: Any, request: PageRequest, *, mention: bool
) -> dict[str, Any]:
    view = object_value(view_value, "inbox view")
    key = "person_mention" if mention else "comment_reply"
    kind = "mention" if mention else "reply"
    event = object_value(view.get(key), f"{kind} event")
    comment = object_value(view.get("comment"), f"{kind} comment")
    creator = object_value(view.get("creator"), f"{kind} creator")
    remote_id, provider_id = _resource(request, kind, event.get("id"), f"{kind} ID")
    _recipient_id, recipient_provider_id = _resource(
        request, "person", event.get("recipient_id"), f"{kind} recipient ID"
    )
    if recipient_provider_id != request.provider_account_id:
        raise LemmyReadProviderError(f"Lemmy {kind} does not belong to the selected account")
    actor_id, _actor_provider_id = _resource(
        request, "person", creator.get("id"), f"{kind} creator ID"
    )
    comment_id, _comment_provider_id = _resource(
        request, "comment", comment.get("id"), f"{kind} comment ID"
    )
    return {
        "kind": kind,
        "remote_id": remote_id,
        "provider_id": provider_id,
        "actor_remote_id": actor_id,
        "actor_ap_id": _ap_id(
            creator.get("actor_id"), f"{kind} creator ActivityPub ID"
        ),
        "object_remote_id": comment_id,
        "content": required_text(comment.get("content"), f"{kind} comment content"),
        "created_at": required_text(event.get("published"), f"{kind} timestamp"),
        "ap_id": _ap_id(comment.get("ap_id"), f"{kind} comment ActivityPub ID"),
        "read": optional_boolean(event.get("read"), f"{kind} read flag"),
    }


def _timestamp(value: str, field: str) -> datetime:
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise LemmyReadProviderError(f"Lemmy {field} is invalid") from error
    if parsed.tzinfo is None:
        raise LemmyReadProviderError(f"Lemmy {field} is invalid")
    return parsed


def pagination_watermark(
    records: list[dict[str, Any]],
    prior: str | None,
    *,
    overlap_cutoff: str | None,
) -> tuple[str | None, bool]:
    """Return a monotonic watermark and whether one-second overlap was crossed."""
    prior_time = _timestamp(prior, "stored watermark") if prior is not None else None
    cutoff_time = (
        _timestamp(overlap_cutoff, "overlap cutoff")
        if overlap_cutoff is not None
        else None
    )
    observed = [
        (required_text(item.get("created_at"), "record timestamp"), None)
        for item in records
    ]
    observed = [(value, _timestamp(value, "record timestamp")) for value, _unused in observed]
    newest_value = prior
    newest_time = prior_time
    for value, item_time in observed:
        if newest_time is None or item_time > newest_time:
            newest_value, newest_time = value, item_time
    crossed = False
    if cutoff_time is not None:
        boundary = cutoff_time - timedelta(seconds=1)
        crossed = any(item_time <= boundary for _value, item_time in observed)
    return newest_value, crossed
