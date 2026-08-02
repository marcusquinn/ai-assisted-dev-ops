#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""GitHub REST route allowlist, fixed GraphQL queries, and serializers."""

from __future__ import annotations

from typing import Any, Callable
from urllib.parse import urlsplit

from _knowledge_social_github import PageRequest, STREAMS
from _knowledge_social_github_contract import (
    ApiResult,
    GitHubReadProviderError,
    object_list,
    object_value,
    observed_at,
    optional_text,
    required_text,
)
from _knowledge_social_github_identity import namespaced_id, node_id, provider_account_id

RestApi = Callable[[str, dict[str, str]], ApiResult]
GraphApi = Callable[[str, dict[str, Any]], ApiResult]
PageResult = ApiResult | dict[str, Any]

EXACT_READ_PATHS = frozenset(
    {
        "/user",
        "/user/repos",
        "/user/starred",
        "/notifications",
        "/user/followers",
        "/user/following",
        "/user/orgs",
        "/user/subscriptions",
    }
)
STREAM_PATHS = {
    "repositories": "/user/repos",
    "stars": "/user/starred",
    "notifications": "/notifications",
    "followers": "/user/followers",
    "following": "/user/following",
    "organizations": "/user/orgs",
    "subscriptions": "/user/subscriptions",
}

IDENTITY_QUERY = """
query AidevopsViewerIdentity {
  viewer { databaseId id login }
}
"""
CONTRIBUTIONS_QUERY = """
query AidevopsViewerContributions {
  viewer {
    contributionsCollection {
      contributionCalendar {
        weeks { contributionDays { contributionCount date } }
      }
    }
  }
}
"""
PROJECTS_QUERY = """
query AidevopsViewerProjects($first: Int!, $after: String) {
  viewer {
    projectsV2(first: $first, after: $after) {
      nodes { closed createdAt id number shortDescription title updatedAt }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""
USER_LISTS_QUERY = """
query AidevopsViewerLists($first: Int!, $after: String) {
  viewer {
    lists(first: $first, after: $after) {
      nodes { createdAt description id isPrivate name slug updatedAt }
      pageInfo { endCursor hasNextPage }
    }
  }
}
"""


def allowlisted_path(path: str) -> bool:
    return path in EXACT_READ_PATHS


def query_keys_for_path(path: str) -> frozenset[str]:
    if path == "/user":
        return frozenset()
    if path == "/notifications":
        return frozenset({"all", "participating", "per_page", "page", "since", "before"})
    if path in ("/user/repos", "/user/starred"):
        return frozenset({"affiliation", "direction", "page", "per_page", "sort", "visibility"})
    return frozenset({"page", "per_page"})


def _resource(kind: str, item: dict[str, Any]) -> str:
    value = item.get("node_id", item.get("id"))
    try:
        return namespaced_id(kind, value)
    except RuntimeError as error:
        raise GitHubReadProviderError(str(error)) from error


def _account(item: dict[str, Any], _request: PageRequest) -> dict[str, Any]:
    numeric = provider_account_id(item.get("id"))
    return {
        "kind": "account",
        "remote_id": _resource("account", item),
        "provider_account_id": numeric,
        "node_id": node_id(item.get("node_id")),
        "login": required_text(item.get("login"), "account login"),
    }


def _repository(item: dict[str, Any], _request: PageRequest) -> dict[str, Any]:
    owner = object_value(item.get("owner"), "repository owner")
    return {
        "kind": "repository",
        "remote_id": _resource("repository", item),
        "node_id": node_id(item.get("node_id")),
        "name": required_text(item.get("name"), "repository name"),
        "full_name": required_text(item.get("full_name"), "repository full name"),
        "description": optional_text(item.get("description"), "repository description"),
        "owner_remote_id": _resource("account", owner),
        "private": item.get("private") if isinstance(item.get("private"), bool) else None,
        "archived": item.get("archived") if isinstance(item.get("archived"), bool) else None,
        "created_at": optional_text(item.get("created_at"), "repository creation timestamp"),
        "updated_at": optional_text(item.get("updated_at"), "repository update timestamp"),
    }


def _organization(item: dict[str, Any], _request: PageRequest) -> dict[str, Any]:
    return {
        "kind": "organization",
        "remote_id": _resource("organization", item),
        "node_id": node_id(item.get("node_id")),
        "login": required_text(item.get("login"), "organization login"),
        "description": optional_text(item.get("description"), "organization description"),
    }


def _notification(item: dict[str, Any], _request: PageRequest) -> dict[str, Any]:
    subject = object_value(item.get("subject"), "notification subject")
    repository = object_value(item.get("repository"), "notification repository")
    notification_id = required_text(item.get("id"), "notification ID")
    return {
        "kind": "notification",
        "remote_id": namespaced_id("notification", notification_id),
        "notification_id": notification_id,
        "reason": required_text(item.get("reason"), "notification reason"),
        "unread": item.get("unread") if isinstance(item.get("unread"), bool) else None,
        "updated_at": optional_text(item.get("updated_at"), "notification timestamp"),
        "title": required_text(subject.get("title"), "notification title"),
        "subject_type": required_text(subject.get("type"), "notification subject type"),
        "repository_remote_id": _resource("repository", repository),
    }


def _user_list(item: dict[str, Any], _request: PageRequest) -> dict[str, Any]:
    list_id = node_id(item.get("id"))
    return {
        "kind": "user_list",
        "remote_id": namespaced_id("user_list", list_id),
        "name": required_text(item.get("name"), "user list name"),
        "description": optional_text(item.get("description"), "user list description"),
        "slug": required_text(item.get("slug"), "user list slug"),
        "private": item.get("isPrivate") if isinstance(item.get("isPrivate"), bool) else None,
        "created_at": optional_text(item.get("createdAt"), "user list creation timestamp"),
        "updated_at": optional_text(item.get("updatedAt"), "user list update timestamp"),
    }


SERIALIZERS = {
    "repositories": _repository,
    "stars": _repository,
    "notifications": _notification,
    "followers": _account,
    "following": _account,
    "organizations": _organization,
    "subscriptions": _repository,
}


def _rest_path(request: PageRequest) -> tuple[str, dict[str, str]]:
    path = STREAM_PATHS[request.stream]
    params = {"per_page": str(min(request.limit, 100))}
    if request.stream == "repositories":
        params["affiliation"] = "owner,collaborator,organization_member"
    elif request.stream == "notifications":
        params["all"] = "true"
    return path, params


def _rest_page(api: RestApi, request: PageRequest) -> PageResult:
    initial_path, initial_params = _rest_path(request)
    if request.stop_at is None:
        target, params = initial_path, initial_params
    else:
        parsed = urlsplit(request.stop_at)
        if parsed.scheme != "https" or parsed.netloc != "api.github.com" or parsed.path != initial_path:
            raise GitHubReadProviderError("GitHub pagination link does not match the selected stream")
        target, params = request.stop_at, {}
    result = api(target, params)
    if result.status != 200:
        return result
    source = object_list(result.payload, f"{request.stream} response", limit=100)
    return _page_payload(
        request,
        [SERIALIZERS[request.stream](item, request) for item in source],
        result.next_url,
    )


def _graph_root(result: ApiResult, field: str) -> dict[str, Any]:
    root = object_value(result.payload, "GraphQL response")
    if root.get("errors"):
        raise GitHubReadProviderError("GitHub GraphQL read returned errors")
    data = object_value(root.get("data"), "GraphQL data")
    viewer = object_value(data.get("viewer"), "GraphQL viewer")
    return object_value(viewer.get(field), f"GraphQL {field}")


def _contributions(api: GraphApi, request: PageRequest) -> PageResult:
    if request.stop_at is not None:
        raise GitHubReadProviderError("GitHub contributions do not accept a page cursor")
    result = api(CONTRIBUTIONS_QUERY, {})
    if result.status != 200:
        return result
    collection = _graph_root(result, "contributionsCollection")
    calendar = object_value(collection.get("contributionCalendar"), "contribution calendar")
    weeks = object_list(calendar.get("weeks"), "contribution weeks", limit=54)
    records: list[dict[str, Any]] = []
    for week in weeks:
        days = object_list(week.get("contributionDays"), "contribution days", limit=7)
        for day in days:
            count = day.get("contributionCount")
            date = required_text(day.get("date"), "contribution date")
            if isinstance(count, bool) or not isinstance(count, int) or count < 0:
                raise GitHubReadProviderError("GitHub contribution count is invalid")
            if count:
                records.append({
                    "kind": "contribution",
                    "remote_id": namespaced_id("contribution", date),
                    "date": date,
                    "count": count,
                })
    return _page_payload(request, records, None)


def _projects(api: GraphApi, request: PageRequest) -> PageResult:
    result = api(PROJECTS_QUERY, {"first": min(request.limit, 100), "after": request.stop_at})
    if result.status != 200:
        return result
    connection = _graph_root(result, "projectsV2")
    nodes = object_list(connection.get("nodes"), "GraphQL projects", limit=100)
    info = object_value(connection.get("pageInfo"), "GraphQL project pageInfo")
    has_next = info.get("hasNextPage")
    if not isinstance(has_next, bool):
        raise GitHubReadProviderError("GitHub GraphQL pageInfo is invalid")
    cursor = required_text(info.get("endCursor"), "GraphQL end cursor") if has_next else None
    records = []
    for item in nodes:
        project_id = node_id(item.get("id"))
        records.append({
            "kind": "project",
            "remote_id": namespaced_id("project", project_id),
            "node_id": project_id,
            "number": item.get("number") if isinstance(item.get("number"), int) else None,
            "title": required_text(item.get("title"), "project title"),
            "description": optional_text(item.get("shortDescription"), "project description"),
            "closed": item.get("closed") if isinstance(item.get("closed"), bool) else None,
            "created_at": optional_text(item.get("createdAt"), "project creation timestamp"),
            "updated_at": optional_text(item.get("updatedAt"), "project update timestamp"),
        })
    return _page_payload(request, records, cursor)


def _user_lists(api: GraphApi, request: PageRequest) -> PageResult:
    result = api(USER_LISTS_QUERY, {"first": min(request.limit, 100), "after": request.stop_at})
    if result.status != 200:
        return result
    connection = _graph_root(result, "lists")
    nodes = object_list(connection.get("nodes"), "GraphQL user lists", limit=100)
    info = object_value(connection.get("pageInfo"), "GraphQL user list pageInfo")
    has_next = info.get("hasNextPage")
    if not isinstance(has_next, bool):
        raise GitHubReadProviderError("GitHub GraphQL pageInfo is invalid")
    cursor = required_text(info.get("endCursor"), "GraphQL end cursor") if has_next else None
    records = [_user_list(item, request) for item in nodes]
    return _page_payload(request, records, cursor)


def _page_payload(
    request: PageRequest, records: list[dict[str, Any]], next_cursor: str | None
) -> dict[str, Any]:
    return {
        "status": 200,
        "observed_at": observed_at(),
        "data": records,
        "meta": {
            "stream": request.stream,
            "instance_id": request.instance_id,
            "transport": STREAMS[request.stream].transport,
            "next_cursor": next_cursor,
            "complete": next_cursor is None,
            "snapshot": True,
        },
    }


def page(rest: RestApi, graph: GraphApi, request: PageRequest) -> PageResult:
    if request.stream == "contributions":
        return _contributions(graph, request)
    if request.stream == "projects_v2":
        return _projects(graph, request)
    if request.stream == "user_lists":
        return _user_lists(graph, request)
    return _rest_page(rest, request)
