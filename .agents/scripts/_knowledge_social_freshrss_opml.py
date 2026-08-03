#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict, entity-disabled, bounded OPML parsing."""

from __future__ import annotations

from typing import Any
from xml.etree import ElementTree

from _knowledge_social_freshrss_contract import (
    FreshRSSReadProviderError,
    optional_text,
    safe_url,
)
from _knowledge_social_freshrss_identity import resource_id

MAX_OPML_BYTES = 8 * 1024 * 1024
MAX_OPML_ATTRIBUTES = 64
MAX_OPML_DEPTH = 128
MAX_OPML_NODES = 50_000


def _invalid() -> FreshRSSReadProviderError:
    return FreshRSSReadProviderError("FreshRSS OPML response is invalid")


def _attributes(values: list[tuple[str, str | None]]) -> dict[str, str]:
    if len(values) > MAX_OPML_ATTRIBUTES:
        raise _invalid()
    result: dict[str, str] = {}
    for raw_key, raw_value in values:
        key = raw_key.casefold()
        if raw_value is None or key in result:
            raise _invalid()
        result[key] = raw_value
    return result


def _feed_record(
    attributes: dict[str, str], installation_id: str, folders: list[str]
) -> dict[str, Any]:
    feed_url = safe_url(attributes.get("xmlurl"), "OPML feed URL")
    if feed_url is None:
        raise _invalid()
    title = optional_text(
        attributes.get("title", attributes.get("text")), "OPML title", limit=4096
    )
    return {
        "kind": "feed",
        "remote_id": resource_id(installation_id, "opml_feed", feed_url),
        "title": title,
        "url": feed_url,
        "html_url": safe_url(attributes.get("htmlurl"), "OPML site URL"),
        "description": optional_text(attributes.get("description"), "OPML description"),
        "feed_type": optional_text(
            attributes.get("type"), "OPML feed type", limit=4096
        ),
        "category": "/".join(folders) or None,
    }


def _require_whitespace(value: str | None) -> None:
    if value is not None and value.strip():
        raise _invalid()


def _validate_tree(root: ElementTree.Element) -> None:
    nodes = 0
    pending = [(root, 1)]
    while pending:
        element, depth = pending.pop()
        nodes += 1
        if nodes > MAX_OPML_NODES or depth > MAX_OPML_DEPTH:
            raise _invalid()
        if not isinstance(element.tag, str):
            raise _invalid()
        if len(element.attrib) > MAX_OPML_ATTRIBUTES:
            raise _invalid()
        pending.extend((child, depth + 1) for child in element)


def _outline_records(
    element: ElementTree.Element,
    installation_id: str,
    limit: int,
    folders: list[str],
    records: list[dict[str, Any]],
) -> None:
    if element.tag != "outline":
        raise _invalid()
    _require_whitespace(element.text)
    attributes = _attributes(list(element.attrib.items()))
    title = optional_text(
        attributes.get("title", attributes.get("text")), "OPML title", limit=4096
    )
    children = list(element)
    if any(child.tag != "outline" for child in children):
        raise _invalid()
    if any(child.tail is not None and child.tail.strip() for child in children):
        raise _invalid()
    if "xmlurl" in attributes:
        if children:
            raise _invalid()
        records.append(_feed_record(attributes, installation_id, folders))
        if len(records) > limit:
            raise FreshRSSReadProviderError(
                "FreshRSS OPML response exceeds the item safety limit"
            )
        return
    if title:
        folders.append(title)
    for child in children:
        _outline_records(child, installation_id, limit, folders, records)
    if title:
        folders.pop()


def _document_records(
    root: ElementTree.Element, installation_id: str, limit: int
) -> list[dict[str, Any]]:
    if root.tag != "opml":
        raise _invalid()
    _require_whitespace(root.text)
    children = list(root)
    if any(child.tag not in {"head", "body"} for child in children):
        raise _invalid()
    heads = [index for index, child in enumerate(children) if child.tag == "head"]
    bodies = [index for index, child in enumerate(children) if child.tag == "body"]
    if len(heads) > 1 or len(bodies) != 1:
        raise _invalid()
    if heads and heads[0] > bodies[0]:
        raise _invalid()
    if any(child.tail is not None and child.tail.strip() for child in children):
        raise _invalid()
    body = children[bodies[0]]
    _require_whitespace(body.text)
    outlines = list(body)
    if any(child.tag != "outline" for child in outlines):
        raise _invalid()
    records: list[dict[str, Any]] = []
    folders: list[str] = []
    for outline in outlines:
        _require_whitespace(outline.tail)
        _outline_records(outline, installation_id, limit, folders, records)
    return records


def parse_opml(payload: Any, installation_id: str, limit: int) -> list[dict[str, Any]]:
    if not isinstance(payload, str):
        raise _invalid()
    if len(payload.encode()) > MAX_OPML_BYTES:
        raise _invalid()
    upper = payload.upper()
    for marker in ("<!DOCTYPE", "<!ENTITY"):
        if marker in upper:
            raise _invalid()
    try:
        root = ElementTree.fromstring(payload)
        _validate_tree(root)
        return _document_records(root, installation_id, limit)
    except (ElementTree.ParseError, RecursionError) as error:
        raise _invalid() from error
