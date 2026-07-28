#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Normalize publication membership and following relationships."""

from __future__ import annotations

from _knowledge_social_medium_common import (
    PROFILE_HANDLE,
    _digest_id,
    _node_href,
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


def parse_profile_publications(
    builder: MediumArchiveBuilder, document: HtmlNode
) -> int:
    if first_descendant(document, HtmlSelector(tag="ul")) is None:
        raise SocialStoreError("Medium publication membership schema is unrecognized")
    processed = 0
    for anchor in descendants(document, HtmlSelector(tag="a", attr_name="href")):
        url = _node_href(anchor)
        label = text(anchor)
        if url is None or not label:
            raise SocialStoreError("Medium publication membership URL is invalid")
        role = next(
            (value for value in ("editor", "writer") if value in label.casefold()),
            "member",
        )
        publication_id = _digest_id("medium_publication", url)
        builder.add_object(
            MediumObjectRecord(
                "publication",
                publication_id,
                label,
                None,
                "relationship",
                {"source": PROVENANCE, "canonical_url": url},
            )
        )
        builder.add_activity(
            "publication_membership",
            _digest_id(
                "medium_publication_membership",
                builder.identity.account_id,
                publication_id,
                role,
            ),
            publication_id,
            None,
            {"source": PROVENANCE, "role": role},
        )
        processed += 1
    return processed


def parse_following(
    builder: MediumArchiveBuilder, category: str, document: HtmlNode
) -> int:
    target_type = {
        "users_following": "user",
        "publications_following": "publication",
        "topics_following": "topic",
    }[category]
    anchors = descendants(document, HtmlSelector(tag="a", attr_name="href"))
    if not anchors and text(document):
        raise SocialStoreError("Medium following schema is unrecognized")
    processed = 0
    for anchor in anchors:
        url = _node_href(anchor)
        label = text(anchor)
        if url is None or not label:
            raise SocialStoreError("Medium following entry URL is invalid")
        target_id = _digest_id(f"medium_{target_type}", url)
        if target_type == "user":
            match = PROFILE_HANDLE.search(label)
            handle = match.group(1) if match is not None else None
            builder.add_account(
                target_id,
                handle,
                label.removeprefix("@") or None,
                {"source": PROVENANCE, "profile_url": url, "relationship": "followed"},
            )
        else:
            builder.add_object(
                MediumObjectRecord(
                    target_type,
                    target_id,
                    label,
                    None,
                    "relationship",
                    {"source": PROVENANCE, "canonical_url": url},
                )
            )
        builder.add_activity(
            f"follow_{target_type}",
            _digest_id(
                f"medium_follow_{target_type}", builder.identity.account_id, target_id
            ),
            target_id,
            None,
            {"source": PROVENANCE},
        )
        processed += 1
    return processed
