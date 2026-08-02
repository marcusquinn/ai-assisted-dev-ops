#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Fixed Hashnode read queries, connection pagination, and serializers."""

from __future__ import annotations

import base64
import json
from dataclasses import dataclass
from typing import Any, Callable

from _knowledge_social_hashnode import PageRequest
from _knowledge_social_hashnode_contract import (
    ApiResult,
    HashnodeReadProviderError,
    nonnegative_int,
    object_list,
    object_value,
    observed_at,
    optional_text,
    public_url,
    required_text,
)
from _knowledge_social_hashnode_identity import (
    INSTANCE_ID,
    namespaced_id,
    opaque_id,
    provider_account_id,
    username,
)
from knowledge_social_import import canonical_json, reject_credentials

GraphApi = Callable[[str, dict[str, Any]], ApiResult]
PageResult = ApiResult | dict[str, Any]
ROUTE_CURSOR_PREFIX = "hashnode-route-v1:"


@dataclass(frozen=True)
class NestedRoute:
    root_field: str
    outer_field: str
    inner_field: str
    outer_validator: Callable[[dict[str, Any], PageRequest], dict[str, Any]]
    serializer: Callable[
        [dict[str, Any], dict[str, Any], PageRequest], dict[str, Any]
    ]

IDENTITY_FIELDS = """
    id username name tagline location dateJoined
    bio { text }
"""
IDENTITY_QUERY = f"""
query AidevopsHashnodeIdentity {{
  me {{ {IDENTITY_FIELDS} }}
}}
"""
PROFILE_QUERY = f"""
query AidevopsHashnodeProfile {{
  me {{ {IDENTITY_FIELDS} }}
}}
"""
PUBLICATIONS_QUERY = """
query AidevopsHashnodePublications($first: Int!, $after: String) {
  me {
    id username
    publications(first: $first, after: $after) {
      edges {
        cursor
        node {
          id title url isTeam followersCount about { text }
          author { id username name }
        }
      }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""
POSTS_QUERY = """
query AidevopsHashnodePosts($username: String!, $first: Int!, $after: String) {
  user(username: $username) {
    id username
    posts(first: $first, after: $after) {
      edges {
        cursor
        node {
          id title subtitle slug url brief publishedAt updatedAt
          reactionCount responseCount replyCount
          content { markdown text }
          author { id username name }
          publication { id title url author { id username } }
          tags { id name slug }
        }
      }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""
DRAFTS_QUERY = """
query AidevopsHashnodeDrafts(
  $publicationAfter: String, $first: Int!, $after: String
) {
  me {
    id username
    publications(first: 1, after: $publicationAfter) {
      edges {
        cursor
        node {
          id title url author { id username }
          drafts(first: $first, after: $after) {
            edges {
              cursor
              node {
                id title subtitle slug updatedAt scheduledDate isSubmittedForReview
                content { markdown text }
                author { id username name }
                tags { id name slug }
              }
            }
            pageInfo { endCursor hasNextPage }
          }
        }
      }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""
COMMENTS_QUERY = """
query AidevopsHashnodeComments(
  $username: String!, $postAfter: String, $first: Int!, $after: String
) {
  user(username: $username) {
    id username
    posts(first: 1, after: $postAfter) {
      edges {
        cursor
        node {
          id title author { id username }
          publication { id title author { id username } }
          comments(first: $first, after: $after) {
            edges {
              cursor
              node {
                id dateAdded totalReactions content { text }
                author { id username name }
              }
            }
            pageInfo { endCursor hasNextPage }
          }
        }
      }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""
REACTIONS_QUERY = """
query AidevopsHashnodeReactions(
  $username: String!, $postAfter: String, $first: Int!, $after: String
) {
  user(username: $username) {
    id username
    posts(first: 1, after: $postAfter) {
      edges {
        cursor
        node {
          id title author { id username }
          publication { id title author { id username } }
          likedBy(first: $first, after: $after) {
            edges { cursor node { id username name } }
            pageInfo { endCursor hasNextPage }
          }
        }
      }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""
FOLLOWERS_QUERY = """
query AidevopsHashnodeFollowers($first: Int!, $after: String) {
  me {
    id username
    followers(first: $first, after: $after) {
      edges { cursor node { id username name tagline } }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""
FOLLOWING_QUERY = """
query AidevopsHashnodeFollowing($first: Int!, $after: String) {
  me {
    id username
    follows(first: $first, after: $after) {
      edges { cursor node { id username name tagline } }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""

QUERY_VARIABLES = {
    IDENTITY_QUERY: frozenset(),
    PROFILE_QUERY: frozenset(),
    PUBLICATIONS_QUERY: frozenset({"first", "after"}),
    POSTS_QUERY: frozenset({"username", "first", "after"}),
    DRAFTS_QUERY: frozenset({"publicationAfter", "first", "after"}),
    COMMENTS_QUERY: frozenset({"username", "postAfter", "first", "after"}),
    REACTIONS_QUERY: frozenset({"username", "postAfter", "first", "after"}),
    FOLLOWERS_QUERY: frozenset({"first", "after"}),
    FOLLOWING_QUERY: frozenset({"first", "after"}),
}
ALLOWED_QUERIES = frozenset(QUERY_VARIABLES)


def _route_state(value: str | None) -> dict[str, Any]:
    if value is None:
        return {}
    if not value.startswith(ROUTE_CURSOR_PREFIX):
        raise HashnodeReadProviderError("Hashnode route cursor has an unsupported version")
    try:
        raw = value.removeprefix(ROUTE_CURSOR_PREFIX)
        parsed = json.loads(base64.urlsafe_b64decode(raw + "=" * (-len(raw) % 4)))
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        raise HashnodeReadProviderError("Hashnode route cursor is invalid") from error
    if not isinstance(parsed, dict):
        raise HashnodeReadProviderError("Hashnode route cursor has an invalid shape")
    reject_credentials(parsed)
    return parsed


def _encode_route_state(state: dict[str, Any]) -> str:
    reject_credentials(state)
    encoded = base64.urlsafe_b64encode(canonical_json(state).encode()).decode("ascii")
    return f"{ROUTE_CURSOR_PREFIX}{encoded.rstrip('=')}"


def _graphql_root(result: ApiResult, field: str) -> dict[str, Any]:
    root = object_value(result.payload, "GraphQL response")
    if root.get("errors"):
        raise HashnodeReadProviderError("Hashnode GraphQL read returned errors")
    data = object_value(root.get("data"), "GraphQL data")
    return object_value(data.get(field), f"GraphQL {field}")


def _verify_account(node: dict[str, Any], request: PageRequest) -> None:
    if (
        provider_account_id(node.get("id")) != request.provider_account_id
        or username(node.get("username")) != request.username
    ):
        raise HashnodeReadProviderError(
            "selected Hashnode account does not match the configured connection"
        )


def _content(value: Any, field: str) -> dict[str, str | None]:
    if value is None:
        return {"markdown": None, "text": None}
    content = object_value(value, field)
    return {
        "markdown": optional_text(content.get("markdown"), f"{field} markdown"),
        "text": optional_text(content.get("text"), f"{field} text"),
    }


def _account(node: dict[str, Any]) -> dict[str, Any]:
    remote = provider_account_id(node.get("id"))
    return {
        "provider_account_id": remote,
        "remote_id": namespaced_id("account", remote),
        "username": username(node.get("username")),
        "name": optional_text(node.get("name"), "account name"),
        "tagline": optional_text(node.get("tagline"), "account tagline"),
    }


def _publication(node: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    publication_id = opaque_id(node.get("id"), "publication ID")
    author = object_value(node.get("author"), "publication author")
    _verify_account(author, request)
    about = _content(node.get("about"), "publication about")
    is_team = node.get("isTeam")
    if is_team is not None and not isinstance(is_team, bool):
        raise HashnodeReadProviderError("Hashnode publication team flag is invalid")
    return {
        "kind": "publication",
        "remote_id": namespaced_id("publication", publication_id),
        "publication_id": publication_id,
        "title": required_text(node.get("title"), "publication title"),
        "url": public_url(node.get("url"), "publication URL"),
        "about": about["text"],
        "is_team": is_team,
        "followers_count": nonnegative_int(
            node.get("followersCount"), "publication follower count", optional=True
        ),
        "author": _account(author),
    }


def _tags(value: Any) -> list[dict[str, str]]:
    tags = object_list(value or [], "post tags", limit=15)
    return [
        {
            "id": opaque_id(item.get("id"), "tag ID"),
            "name": required_text(item.get("name"), "tag name"),
            "slug": required_text(item.get("slug"), "tag slug"),
        }
        for item in tags
    ]


def _publication_summary(value: Any, request: PageRequest) -> dict[str, Any]:
    publication = object_value(value, "post publication")
    publication_id = opaque_id(publication.get("id"), "publication ID")
    author = object_value(publication.get("author"), "publication author")
    _verify_account(author, request)
    return {
        "remote_id": namespaced_id("publication", publication_id),
        "publication_id": publication_id,
        "title": required_text(publication.get("title"), "publication title"),
        "url": public_url(publication.get("url"), "publication URL"),
    }


def _post(node: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    post_id = opaque_id(node.get("id"), "post ID")
    author = object_value(node.get("author"), "post author")
    _verify_account(author, request)
    content = _content(node.get("content"), "post content")
    return {
        "kind": "post",
        "remote_id": namespaced_id("post", post_id),
        "post_id": post_id,
        "title": required_text(node.get("title"), "post title"),
        "subtitle": optional_text(node.get("subtitle"), "post subtitle"),
        "slug": required_text(node.get("slug"), "post slug"),
        "url": public_url(node.get("url"), "post URL"),
        "brief": optional_text(node.get("brief"), "post brief"),
        "markdown": content["markdown"],
        "text": content["text"],
        "published_at": required_text(node.get("publishedAt"), "post publish date"),
        "updated_at": optional_text(node.get("updatedAt"), "post update date"),
        "reaction_count": nonnegative_int(node.get("reactionCount"), "reaction count"),
        "response_count": nonnegative_int(node.get("responseCount"), "response count"),
        "reply_count": nonnegative_int(node.get("replyCount"), "reply count"),
        "author": _account(author),
        "publication": _publication_summary(node.get("publication"), request),
        "tags": _tags(node.get("tags")),
    }


def _draft(
    node: dict[str, Any], publication: dict[str, Any], request: PageRequest
) -> dict[str, Any]:
    draft_id = opaque_id(node.get("id"), "draft ID")
    author = object_value(node.get("author"), "draft author")
    _verify_account(author, request)
    content = _content(node.get("content"), "draft content")
    review = node.get("isSubmittedForReview")
    if review is not None and not isinstance(review, bool):
        raise HashnodeReadProviderError("Hashnode draft review flag is invalid")
    return {
        "kind": "draft",
        "remote_id": namespaced_id("draft", draft_id),
        "draft_id": draft_id,
        "title": optional_text(node.get("title"), "draft title"),
        "subtitle": optional_text(node.get("subtitle"), "draft subtitle"),
        "slug": optional_text(node.get("slug"), "draft slug"),
        "markdown": content["markdown"],
        "text": content["text"],
        "updated_at": required_text(node.get("updatedAt"), "draft update date"),
        "scheduled_at": optional_text(node.get("scheduledDate"), "draft schedule date"),
        "submitted_for_review": review,
        "author": _account(author),
        "publication": publication,
        "tags": _tags(node.get("tags")),
    }


def _post_context(node: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    post_id = opaque_id(node.get("id"), "post ID")
    author = object_value(node.get("author"), "post author")
    _verify_account(author, request)
    return {
        "remote_id": namespaced_id("post", post_id),
        "post_id": post_id,
        "title": required_text(node.get("title"), "post title"),
        "publication": _publication_summary(node.get("publication"), request),
    }


def _comment(
    node: dict[str, Any], post: dict[str, Any], _request: PageRequest
) -> dict[str, Any]:
    comment_id = opaque_id(node.get("id"), "comment ID")
    content = _content(node.get("content"), "comment content")
    return {
        "kind": "comment",
        "remote_id": namespaced_id("comment", comment_id),
        "comment_id": comment_id,
        "text": content["text"],
        "date_added": required_text(node.get("dateAdded"), "comment date"),
        "reaction_count": nonnegative_int(
            node.get("totalReactions"), "comment reaction count"
        ),
        "author": _account(object_value(node.get("author"), "comment author")),
        "post": post,
    }


def _reaction(
    node: dict[str, Any], post: dict[str, Any], _request: PageRequest
) -> dict[str, Any]:
    actor = _account(node)
    return {
        "kind": "reaction",
        "remote_id": namespaced_id(
            "reaction", f"{post['post_id']}:{actor['provider_account_id']}:like"
        ),
        "reaction_type": "like",
        "actor": actor,
        "post": post,
    }


def _page_info(connection: dict[str, Any]) -> tuple[bool, str | None]:
    info = object_value(connection.get("pageInfo"), "connection pageInfo")
    has_next = info.get("hasNextPage")
    if not isinstance(has_next, bool):
        raise HashnodeReadProviderError("Hashnode connection pageInfo is invalid")
    end = optional_text(info.get("endCursor"), "connection end cursor")
    if has_next and not end:
        raise HashnodeReadProviderError("Hashnode connection omitted its next cursor")
    return has_next, end


def _edges(
    connection: dict[str, Any], field: str, limit: int
) -> list[tuple[str, dict[str, Any]]]:
    edges = object_list(connection.get("edges"), f"{field} edges", limit=limit)
    return [
        (
            required_text(edge.get("cursor"), f"{field} edge cursor"),
            object_value(edge.get("node"), f"{field} edge node"),
        )
        for edge in edges
    ]


def _next_cursor(current: str | None, has_next: bool, end: str | None) -> str | None:
    if not has_next:
        return None
    if end == current:
        raise HashnodeReadProviderError("Hashnode connection cursor did not advance")
    return end


def _page_payload(
    request: PageRequest, records: list[dict[str, Any]], next_cursor: str | None
) -> dict[str, Any]:
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "instance_id": INSTANCE_ID,
            "transport": "graphql",
            "next_cursor": next_cursor,
            "complete": next_cursor is None,
            "snapshot": True,
        },
    }


def _simple_connection(
    result: ApiResult,
    request: PageRequest,
    root_field: str,
    connection_field: str,
    serializer: Callable[[dict[str, Any], PageRequest], dict[str, Any]],
) -> PageResult:
    if result.status != 200:
        return result
    state = _route_state(request.stop_at)
    if set(state) - {"after"}:
        raise HashnodeReadProviderError("Hashnode route cursor has an invalid shape")
    after = optional_text(state.get("after"), "route cursor")
    root = _graphql_root(result, root_field)
    _verify_account(root, request)
    connection = object_value(root.get(connection_field), f"{connection_field} connection")
    edges = _edges(connection, connection_field, request.limit)
    has_next, end = _page_info(connection)
    next_after = _next_cursor(after, has_next, end)
    next_state = _encode_route_state({"after": next_after}) if next_after else None
    return _page_payload(
        request, [serializer(node, request) for _cursor, node in edges], next_state
    )


def _nested_connection(
    result: ApiResult,
    request: PageRequest,
    route: NestedRoute,
) -> PageResult:
    if result.status != 200:
        return result
    state = _route_state(request.stop_at)
    expected = {"outer_after", "inner_after", "outer_id"}
    if set(state) - expected:
        raise HashnodeReadProviderError("Hashnode nested cursor has an invalid shape")
    outer_after = optional_text(state.get("outer_after"), "outer cursor")
    inner_after = optional_text(state.get("inner_after"), "inner cursor")
    prior_outer_id = optional_text(state.get("outer_id"), "outer resource ID")
    if (inner_after is None) != (prior_outer_id is None):
        raise HashnodeReadProviderError("Hashnode nested cursor is incomplete")
    root = _graphql_root(result, route.root_field)
    _verify_account(root, request)
    outer = object_value(
        root.get(route.outer_field), f"{route.outer_field} connection"
    )
    outer_edges = _edges(outer, route.outer_field, 1)
    outer_has_next, outer_end = _page_info(outer)
    if not outer_edges:
        if outer_has_next:
            raise HashnodeReadProviderError("Hashnode nested connection page is empty")
        return _page_payload(request, [], None)
    outer_cursor, outer_node = outer_edges[0]
    if outer_end != outer_cursor:
        raise HashnodeReadProviderError("Hashnode outer connection cursor is inconsistent")
    outer_context = route.outer_validator(outer_node, request)
    outer_id = required_text(outer_context.get("remote_id"), "outer resource ID")
    if prior_outer_id is not None and prior_outer_id != outer_id:
        raise HashnodeReadProviderError("Hashnode nested cursor changed resources")
    inner = object_value(
        outer_node.get(route.inner_field), f"{route.inner_field} connection"
    )
    inner_edges = _edges(inner, route.inner_field, request.limit)
    inner_has_next, inner_end = _page_info(inner)
    records = [
        route.serializer(node, outer_context, request) for _cursor, node in inner_edges
    ]
    if inner_has_next:
        next_inner = _next_cursor(inner_after, True, inner_end)
        next_state = {
            "outer_after": outer_after,
            "inner_after": next_inner,
            "outer_id": outer_id,
        }
    elif outer_has_next:
        next_outer = _next_cursor(outer_after, True, outer_end)
        next_state = {
            "outer_after": next_outer,
            "inner_after": None,
            "outer_id": None,
        }
    else:
        return _page_payload(request, records, None)
    return _page_payload(request, records, _encode_route_state(next_state))


def _profile(api: GraphApi, request: PageRequest) -> PageResult:
    if request.stop_at is not None:
        raise HashnodeReadProviderError("Hashnode profile does not accept a page cursor")
    result = api(PROFILE_QUERY, {})
    if result.status != 200:
        return result
    viewer = _graphql_root(result, "me")
    _verify_account(viewer, request)
    bio = _content(viewer.get("bio"), "profile bio")
    record = {
        "kind": "profile",
        "remote_id": namespaced_id("profile", request.provider_account_id),
        "username": request.username,
        "name": optional_text(viewer.get("name"), "profile name"),
        "tagline": optional_text(viewer.get("tagline"), "profile tagline"),
        "location": optional_text(viewer.get("location"), "profile location"),
        "date_joined": optional_text(viewer.get("dateJoined"), "profile join date"),
        "bio": bio["text"],
    }
    return _page_payload(request, [record], None)


def _publications(api: GraphApi, request: PageRequest) -> PageResult:
    state = _route_state(request.stop_at)
    after = optional_text(state.get("after"), "publication cursor")
    result = api(PUBLICATIONS_QUERY, {"first": request.limit, "after": after})
    return _simple_connection(
        result, request, "me", "publications", _publication
    )


def _posts(api: GraphApi, request: PageRequest) -> PageResult:
    state = _route_state(request.stop_at)
    after = optional_text(state.get("after"), "post cursor")
    result = api(
        POSTS_QUERY,
        {"username": request.username, "first": request.limit, "after": after},
    )
    return _simple_connection(result, request, "user", "posts", _post)


def _draft_publication(node: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    summary = _publication_summary(node, request)
    return {**summary, "remote_id": summary["remote_id"]}


def _drafts(api: GraphApi, request: PageRequest) -> PageResult:
    state = _route_state(request.stop_at)
    result = api(
        DRAFTS_QUERY,
        {
            "publicationAfter": state.get("outer_after"),
            "first": request.limit,
            "after": state.get("inner_after"),
        },
    )
    return _nested_connection(
        result,
        request,
        NestedRoute("me", "publications", "drafts", _draft_publication, _draft),
    )


def _post_interactions(
    api: GraphApi,
    request: PageRequest,
    query: str,
    route: NestedRoute,
) -> PageResult:
    state = _route_state(request.stop_at)
    result = api(
        query,
        {
            "username": request.username,
            "postAfter": state.get("outer_after"),
            "first": request.limit,
            "after": state.get("inner_after"),
        },
    )
    return _nested_connection(result, request, route)


def _comments(api: GraphApi, request: PageRequest) -> PageResult:
    return _post_interactions(
        api,
        request,
        COMMENTS_QUERY,
        NestedRoute("user", "posts", "comments", _post_context, _comment),
    )


def _reactions(api: GraphApi, request: PageRequest) -> PageResult:
    return _post_interactions(
        api,
        request,
        REACTIONS_QUERY,
        NestedRoute("user", "posts", "likedBy", _post_context, _reaction),
    )


def _relationship(node: dict[str, Any], request: PageRequest) -> dict[str, Any]:
    return {"kind": "account", "relation": request.stream, **_account(node)}


def _followers(api: GraphApi, request: PageRequest) -> PageResult:
    state = _route_state(request.stop_at)
    result = api(
        FOLLOWERS_QUERY,
        {"first": request.limit, "after": state.get("after")},
    )
    return _simple_connection(result, request, "me", "followers", _relationship)


def _following(api: GraphApi, request: PageRequest) -> PageResult:
    state = _route_state(request.stop_at)
    result = api(
        FOLLOWING_QUERY,
        {"first": request.limit, "after": state.get("after")},
    )
    return _simple_connection(result, request, "me", "follows", _relationship)


ROUTES = {
    "profile": _profile,
    "publications": _publications,
    "posts": _posts,
    "drafts": _drafts,
    "comments": _comments,
    "reactions": _reactions,
    "followers": _followers,
    "following": _following,
}


def page(api: GraphApi, request: PageRequest) -> PageResult:
    return ROUTES[request.stream](api, request)
