#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Small, non-networking HTML helpers for Medium account exports."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from html.parser import HTMLParser
from typing import Iterator

from knowledge_source_contract import (
    FORBIDDEN_CREDENTIAL_KEYS,
    FORBIDDEN_CREDENTIAL_SUFFIXES,
)
from knowledge_social_store import SocialStoreError

VOID_ELEMENTS = {
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
}
MAX_HTML_DEPTH = 256


def _normalized_name(value: str) -> str:
    return "".join(character for character in value.lower() if character.isalnum())


def _credential_attribute(name: str) -> bool:
    normalized = _normalized_name(name)
    return normalized in FORBIDDEN_CREDENTIAL_KEYS or normalized.endswith(
        FORBIDDEN_CREDENTIAL_SUFFIXES
    )


@dataclass
class HtmlNode:
    """A minimal HTML node retaining only tags, attributes, and text."""

    tag: str
    attrs: dict[str, str]
    children: list[HtmlNode | str] = field(default_factory=list)


@dataclass(frozen=True)
class HtmlSelector:
    """The bounded selector subset understood by the export parser."""

    tag: str | None = None
    class_name: str | None = None
    attr_name: str | None = None
    attr_value: str | None = None


class _TreeParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.root = HtmlNode("document", {})
        self.stack = [self.root]

    def handle_starttag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        normalized_attrs: dict[str, str] = {}
        for name, value in attrs:
            lowered = name.lower()
            if _credential_attribute(lowered):
                raise SocialStoreError(
                    "Medium archive contains credential-shaped HTML attributes"
                )
            normalized_attrs[lowered] = value or ""
        node = HtmlNode(tag.lower(), normalized_attrs)
        self.stack[-1].children.append(node)
        if node.tag not in VOID_ELEMENTS:
            if len(self.stack) > MAX_HTML_DEPTH:
                raise SocialStoreError("Medium archive HTML nesting is too deep")
            self.stack.append(node)

    def handle_startendtag(
        self, tag: str, attrs: list[tuple[str, str | None]]
    ) -> None:
        self.handle_starttag(tag, attrs)
        if tag.lower() not in VOID_ELEMENTS:
            self.stack.pop()

    def handle_endtag(self, tag: str) -> None:
        lowered = tag.lower()
        for index in range(len(self.stack) - 1, 0, -1):
            if self.stack[index].tag == lowered:
                del self.stack[index:]
                return

    def handle_data(self, data: str) -> None:
        self.stack[-1].children.append(data)


def parse_html(payload: bytes) -> HtmlNode:
    """Decode one bounded UTF-8 export member and return its minimal tree."""
    try:
        source = payload.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise SocialStoreError("Medium archive HTML must be valid UTF-8") from error
    if "\x00" in source:
        raise SocialStoreError("Medium archive HTML contains a NUL byte")
    parser = _TreeParser()
    try:
        parser.feed(source)
        parser.close()
    except (SocialStoreError, ValueError) as error:
        if isinstance(error, SocialStoreError):
            raise
        raise SocialStoreError("Medium archive HTML is malformed") from error
    return parser.root


def walk(node: HtmlNode) -> Iterator[HtmlNode]:
    """Yield every element below a node in document order."""
    pending = [
        child for child in reversed(node.children) if isinstance(child, HtmlNode)
    ]
    while pending:
        current = pending.pop()
        yield current
        pending.extend(
            child
            for child in reversed(current.children)
            if isinstance(child, HtmlNode)
        )


def text(node: HtmlNode) -> str:
    """Return normalized descendant text without retaining HTML markup."""
    parts: list[str] = []
    pending: list[HtmlNode | str] = list(reversed(node.children))
    while pending:
        current = pending.pop()
        if isinstance(current, str):
            parts.append(current)
        else:
            pending.extend(reversed(current.children))
    return re.sub(r"\s+", " ", " ".join(parts)).strip()


def classes(node: HtmlNode) -> set[str]:
    return {value for value in node.attrs.get("class", "").split() if value}


def _active_selector(
    selector: HtmlSelector | None, criteria: dict[str, str | None]
) -> HtmlSelector:
    if selector is not None and criteria:
        raise TypeError("pass either a Medium HTML selector or selector keywords")
    return selector if selector is not None else HtmlSelector(**criteria)


def _matches(candidate: HtmlNode, selector: HtmlSelector) -> bool:
    if selector.tag is not None and candidate.tag != selector.tag:
        return False
    if selector.class_name is not None and selector.class_name not in classes(candidate):
        return False
    if selector.attr_name is not None and selector.attr_name not in candidate.attrs:
        return False
    if (
        selector.attr_value is not None
        and candidate.attrs.get(selector.attr_name or "") != selector.attr_value
    ):
        return False
    return True


def descendants(
    node: HtmlNode,
    selector: HtmlSelector | None = None,
    **criteria: str | None,
) -> list[HtmlNode]:
    """Return descendants matching the small selector subset export parsers use."""
    active = _active_selector(selector, criteria)
    return [candidate for candidate in walk(node) if _matches(candidate, active)]


def first_descendant(
    node: HtmlNode,
    selector: HtmlSelector | None = None,
    **criteria: str | None,
) -> HtmlNode | None:
    matches = descendants(node, selector, **criteria)
    return matches[0] if matches else None
