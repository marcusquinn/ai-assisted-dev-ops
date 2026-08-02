#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Dependency-free bounded OPML parsing without Python XML processors."""

from __future__ import annotations

from html.parser import HTMLParser
from typing import Any

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


class _OPMLParser(HTMLParser):
    def __init__(self, installation_id: str, limit: int) -> None:
        super().__init__(convert_charrefs=True)
        self.installation_id = installation_id
        self.limit = limit
        self.records: list[dict[str, Any]] = []
        self.folders: list[str] = []
        self.outlines: list[bool] = []
        self.nodes = 0
        self.seen_opml = False
        self.seen_body = False

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        self.nodes += 1
        if self.nodes > MAX_OPML_NODES:
            raise _invalid()
        name = tag.casefold()
        if name == "opml":
            self.seen_opml = True
            return
        if name == "body":
            self.seen_body = True
            return
        if name == "outline":
            self._start_outline(attrs)

    def _start_outline(self, attrs: list[tuple[str, str | None]]) -> None:
        if not self.seen_body or len(self.outlines) >= MAX_OPML_DEPTH:
            raise _invalid()
        attributes = _attributes(attrs)
        title = optional_text(
            attributes.get("title", attributes.get("text")), "OPML title", limit=4096
        )
        if "xmlurl" not in attributes:
            self.outlines.append(bool(title))
            if title:
                self.folders.append(title)
            return
        self.outlines.append(False)
        self.records.append(_feed_record(attributes, self.installation_id, self.folders))
        if len(self.records) > self.limit:
            raise FreshRSSReadProviderError(
                "FreshRSS OPML response exceeds the item safety limit"
            )

    def handle_endtag(self, tag: str) -> None:
        if tag.casefold() != "outline":
            return
        if not self.outlines:
            raise _invalid()
        if self.outlines.pop():
            self.folders.pop()

    def handle_decl(self, _decl: str) -> None:
        raise _invalid()

    def unknown_decl(self, _data: str) -> None:
        raise _invalid()

    def handle_pi(self, data: str) -> None:
        if not data.casefold().startswith("xml "):
            raise _invalid()

    def result(self) -> list[dict[str, Any]]:
        self.close()
        if not self.seen_opml or not self.seen_body:
            raise _invalid()
        if self.outlines or self.folders:
            raise _invalid()
        return self.records


def parse_opml(payload: Any, installation_id: str, limit: int) -> list[dict[str, Any]]:
    if not isinstance(payload, str):
        raise _invalid()
    if len(payload.encode()) > MAX_OPML_BYTES:
        raise _invalid()
    upper = payload.upper()
    for marker in ("<!DOCTYPE", "<!ENTITY"):
        if marker in upper:
            raise _invalid()
    parser = _OPMLParser(installation_id, limit)
    try:
        parser.feed(payload)
        return parser.result()
    except AssertionError as error:
        raise _invalid() from error
