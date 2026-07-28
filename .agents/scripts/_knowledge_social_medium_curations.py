#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize bookmarks, claps, highlights, and lists from Medium exports."""

from __future__ import annotations

import hashlib
import re
from typing import Any

from _knowledge_social_medium_common import (
    _digest_id,
    _first_with_classes,
    _member_provenance,
    _node_href,
    _timestamp,
)
from _knowledge_social_medium_html import (
    HtmlNode,
    HtmlSelector,
    descendants,
    first_descendant,
    text,
)
from _knowledge_social_medium_types import (
    MediumArchiveBuilder,
    MediumObjectRecord,
    PROVENANCE,
)
from knowledge_social_store import SocialStoreError

CLAP_COUNT = re.compile(r"\+(\d{1,3})\s*(?:—|-)")


def _reference_object(
    builder: MediumArchiveBuilder, url: str, title: str | None, source: str
) -> str:
    remote_id = _digest_id("medium_url", url)
    builder.add_object(
        MediumObjectRecord(
            "story_reference",
            remote_id,
            title,
            None,
            "curated",
            {"source": PROVENANCE, "canonical_url": url, "archive_category": source},
        )
    )
    return remote_id


def _time_from_item(item: HtmlNode) -> tuple[str | None, str | None, bool]:
    node = first_descendant(
        item, HtmlSelector(tag="time", class_name="dt-published")
    )
    value = node.attrs.get("datetime") or text(node) if node is not None else None
    return _timestamp(value)


def _list_items(document: HtmlNode, category: str) -> list[HtmlNode]:
    items = descendants(document, HtmlSelector(tag="li"))
    if not items and first_descendant(document, HtmlSelector(tag="ul")) is None:
        raise SocialStoreError(f"Medium {category} schema is unrecognized")
    return items


def _activity_metadata(
    name: str, raw: str | None, known: bool
) -> dict[str, Any]:
    return {
        "source": PROVENANCE,
        "archive_member": name,
        "timestamp_raw": raw,
        "timestamp_timezone_known": known,
    }


def parse_bookmarks(
    builder: MediumArchiveBuilder, name: str, document: HtmlNode
) -> int:
    processed = 0
    for item in _list_items(document, "bookmark"):
        anchor = first_descendant(
            item, HtmlSelector(tag="a", class_name="h-cite")
        )
        url = _node_href(anchor)
        if anchor is None or url is None:
            raise SocialStoreError("Medium bookmark entry is missing a valid URL")
        object_id = _reference_object(builder, url, text(anchor) or None, "bookmarks")
        occurred_at, raw, known = _time_from_item(item)
        builder.add_activity(
            "bookmark",
            _digest_id("medium_bookmark", builder.identity.account_id, object_id),
            object_id,
            occurred_at,
            _activity_metadata(name, raw, known),
        )
        processed += 1
    return processed


def parse_claps(
    builder: MediumArchiveBuilder, name: str, document: HtmlNode
) -> int:
    processed = 0
    for item in _list_items(document, "clap"):
        anchor = _first_with_classes(item, ("u-like-of", "h-cite"))
        url = _node_href(anchor)
        if anchor is None or url is None:
            raise SocialStoreError("Medium clap entry is missing a valid URL")
        object_id = _reference_object(builder, url, text(anchor) or None, "claps")
        occurred_at, raw, known = _time_from_item(item)
        match = CLAP_COUNT.search(text(item))
        clap_count = int(match.group(1)) if match is not None else None
        if clap_count is not None and not 1 <= clap_count <= 50:
            raise SocialStoreError("Medium archive clap count is outside 1-50")
        metadata = _activity_metadata(name, raw, known)
        metadata["clap_count"] = clap_count
        builder.add_activity(
            "clap",
            _digest_id("medium_clap", builder.identity.account_id, object_id),
            object_id,
            occurred_at,
            metadata,
        )
        processed += 1
    return processed


def parse_highlights(
    builder: MediumArchiveBuilder, name: str, document: HtmlNode
) -> int:
    processed = 0
    for item_index, item in enumerate(_list_items(document, "highlight")):
        source = _first_with_classes(item, ("h-cite", "u-highlight-of"))
        source_url = _node_href(source)
        if source is not None and source_url is None:
            raise SocialStoreError("Medium highlight source URL is invalid")
        marked = descendants(item, HtmlSelector(class_name="markup--highlight"))
        if not marked:
            raise SocialStoreError("Medium highlight entry has no selection marker")
        for selection_index, selection in enumerate(marked):
            selected_text = text(selection)
            if not selected_text:
                raise SocialStoreError("Medium highlight selection is empty")
            identity = source_url or f"{name}:{item_index}"
            remote_id = _digest_id(
                "medium_highlight", identity, str(selection_index), selected_text
            )
            occurred_at, raw, known = _time_from_item(item)
            metadata = _activity_metadata(name, raw, known)
            metadata["source_url"] = source_url
            builder.add_object(
                MediumObjectRecord(
                    "highlight",
                    remote_id,
                    selected_text,
                    occurred_at,
                    "curated",
                    metadata,
                )
            )
            builder.add_activity(
                "highlight",
                _digest_id(
                    "medium_highlight_activity", builder.identity.account_id, remote_id
                ),
                remote_id,
                occurred_at,
                {"source": PROVENANCE},
            )
            processed += 1
    return processed


def parse_lists(
    builder: MediumArchiveBuilder, name: str, payload: bytes, document: HtmlNode
) -> int:
    title_node = first_descendant(document, HtmlSelector(class_name="p-name"))
    summary_node = first_descendant(document, HtmlSelector(class_name="p-summary"))
    title = text(title_node) if title_node is not None else None
    summary = text(summary_node) if summary_node is not None else None
    canonical = first_descendant(
        document, HtmlSelector(tag="a", class_name="p-canonical")
    )
    list_url = _node_href(canonical)
    if not title:
        raise SocialStoreError("Medium archive list is missing its title marker")
    list_id = (
        _digest_id("medium_list", list_url)
        if list_url is not None
        else _digest_id("medium_list", name, hashlib.sha256(payload).hexdigest())
    )
    builder.add_object(
        MediumObjectRecord(
            "list",
            list_id,
            "\n\n".join(value for value in (title, summary) if value) or None,
            None,
            "curated",
            {**_member_provenance(name, payload), "canonical_url": list_url},
            owned=True,
        )
    )
    processed = 1
    selector = HtmlSelector(tag="li", attr_name="data-field", attr_value="post")
    for item in descendants(document, selector):
        anchor = first_descendant(item, HtmlSelector(tag="a", attr_name="href"))
        url = _node_href(anchor)
        if anchor is None or url is None:
            raise SocialStoreError("Medium archive list entry is missing a valid URL")
        object_id = _reference_object(builder, url, text(anchor) or None, "lists")
        builder.add_activity(
            "list_membership",
            _digest_id("medium_list_member", list_id, object_id),
            object_id,
            None,
            {"source": PROVENANCE, "list_remote_id": list_id},
        )
        processed += 1
    return processed
