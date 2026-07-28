#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize authored posts and responses from a Medium export."""

from __future__ import annotations

import hashlib

from _knowledge_social_medium_common import (
    PROFILE_HANDLE,
    PROFILE_URL_HANDLE,
    _digest_id,
    _member_provenance,
    _node_href,
    _timestamp,
)
from _knowledge_social_medium_html import (
    HtmlNode,
    HtmlSelector,
    classes,
    descendants,
    first_descendant,
    text,
    walk,
)
from _knowledge_social_medium_types import (
    MediumArchiveBuilder,
    MediumObjectRecord,
    PROVENANCE,
)
from knowledge_social_store import SocialStoreError


def _post_content(document: HtmlNode) -> str | None:
    body = first_descendant(
        document, HtmlSelector(attr_name="data-field", attr_value="body")
    )
    if body is None:
        body = first_descendant(document, HtmlSelector(class_name="e-content"))
    if body is None:
        raise SocialStoreError("Medium archive post is missing its body marker")
    title_node = first_descendant(document, HtmlSelector(class_name="p-name"))
    if title_node is None:
        title_node = first_descendant(document, HtmlSelector(tag="title"))
    title = text(title_node) if title_node is not None else ""
    return "\n\n".join(part for part in (title, text(body)) if part) or None


def _canonical_url(document: HtmlNode) -> str | None:
    nodes = descendants(
        document, HtmlSelector(tag="a", class_name="p-canonical")
    )
    urls = {_node_href(node) for node in nodes}
    urls.discard(None)
    if len(urls) > 1:
        raise SocialStoreError("Medium archive post canonical URLs conflict")
    return next(iter(urls), None)


def _post_author_handles(document: HtmlNode) -> set[str]:
    handles: set[str] = set()
    nodes = descendants(document, HtmlSelector(tag="a", class_name="p-author"))
    for node in nodes:
        label_match = PROFILE_HANDLE.fullmatch(text(node))
        url_match = PROFILE_URL_HANDLE.search(node.attrs.get("href", ""))
        if label_match:
            handles.add(label_match.group(1))
        if url_match:
            handles.add(url_match.group(1))
    return handles


def _validate_post_author(builder: MediumArchiveBuilder, document: HtmlNode) -> None:
    expected = builder.identity.username
    if expected is None:
        return
    handles = _post_author_handles(document)
    if not handles:
        return
    if expected.casefold() not in {handle.casefold() for handle in handles}:
        raise SocialStoreError("Medium archive post author conflicts with the profile")


def _post_time(document: HtmlNode) -> tuple[str | None, str | None, bool]:
    published = first_descendant(
        document, HtmlSelector(tag="time", class_name="dt-published")
    )
    value = published.attrs.get("datetime") or text(published) if published else None
    return _timestamp(value)


def _post_identity(
    name: str, payload: bytes, document: HtmlNode, canonical_url: str | None
) -> tuple[str, str]:
    explicit_ids = {
        node.attrs[attribute]
        for node in walk(document)
        for attribute in ("data-post-id", "data-response-id")
        if node.attrs.get(attribute)
    }
    if len(explicit_ids) > 1:
        raise SocialStoreError("Medium archive post IDs conflict")
    if explicit_ids:
        return _digest_id("medium_post", next(iter(explicit_ids))), "explicit"
    if canonical_url is not None:
        return _digest_id("medium_post", canonical_url), "canonical_url"
    digest = hashlib.sha256(payload).hexdigest()
    return _digest_id("medium_post", name, digest), "content_addressed"


def parse_post(
    builder: MediumArchiveBuilder, name: str, payload: bytes, document: HtmlNode
) -> int:
    """Normalize one authored post or response member."""
    content = _post_content(document)
    canonical_url = _canonical_url(document)
    _validate_post_author(builder, document)
    occurred_at, timestamp_raw, timezone_known = _post_time(document)
    response_marker = any(
        "u-in-reply-to" in classes(node) or "data-response-id" in node.attrs
        for node in walk(document)
    )
    remote_id, identity_confidence = _post_identity(
        name, payload, document, canonical_url
    )
    provenance = _member_provenance(name, payload)
    provenance.update(
        {
            "canonical_url": canonical_url,
            "identity_confidence": identity_confidence,
            "post_kind": "response" if response_marker else "unclassified_authored",
            "timestamp_raw": timestamp_raw,
            "timestamp_timezone_known": timezone_known,
        }
    )
    builder.add_object(
        MediumObjectRecord(
            "post", remote_id, content, occurred_at, "authored", provenance, owned=True
        )
    )
    builder.add_activity(
        "content_author",
        _digest_id("medium_activity", builder.identity.account_id, remote_id),
        remote_id,
        occurred_at,
        {"source": PROVENANCE, "post_kind": provenance["post_kind"]},
    )
    return 1
