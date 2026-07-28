#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Orchestrate normalization of one validated native Medium archive."""

from __future__ import annotations

import hashlib
from dataclasses import dataclass, field

from _knowledge_social_medium_common import (
    _profile_identity,
    _validate_expected_identity,
    normalize_exported_at,
)
from _knowledge_social_medium_curations import (
    parse_bookmarks,
    parse_claps,
    parse_highlights,
    parse_lists,
)
from _knowledge_social_medium_html import HtmlNode
from _knowledge_social_medium_posts import parse_post
from _knowledge_social_medium_relationships import (
    parse_following,
    parse_profile_publications,
)
from _knowledge_social_medium_types import (
    CATEGORY_PREFIXES,
    MediumArchiveBuilder,
    MediumArchiveRequest,
    ParsedMediumArchive,
)
from _knowledge_social_medium_zip import (
    MediumArchiveContents,
    read_archive_contents,
    read_regular_archive,
)
from knowledge_social_store import SocialStoreError, validate_opaque


@dataclass
class _ArchiveProgress:
    present: set[str] = field(default_factory=set)
    recognized: int = 1
    unrecognized: int = 0


def _category(name: str) -> str | None:
    for category, prefixes in CATEGORY_PREFIXES.items():
        if any(name == prefix or name.startswith(prefix) for prefix in prefixes):
            return category
    return None


def _parse_category_member(
    builder: MediumArchiveBuilder,
    category: str,
    name: str,
    payload: bytes,
    document: HtmlNode,
) -> int:
    if category == "posts":
        processed = parse_post(builder, name, payload, document)
    elif category == "bookmarks":
        processed = parse_bookmarks(builder, name, document)
    elif category == "claps":
        processed = parse_claps(builder, name, document)
    elif category == "highlights":
        processed = parse_highlights(builder, name, document)
    elif category == "lists":
        processed = parse_lists(builder, name, payload, document)
    elif category == "publication_membership":
        processed = parse_profile_publications(builder, document)
    else:
        processed = parse_following(builder, category, document)
    return processed


def _normalize_members(
    builder: MediumArchiveBuilder, contents: MediumArchiveContents
) -> _ArchiveProgress:
    progress = _ArchiveProgress()
    members = contents.members
    documents = contents.documents
    for info in members:
        name = info.filename
        if name == "profile/profile.html":
            continue
        category = _category(name)
        if category is None:
            progress.unrecognized += 1
            continue
        if not name.lower().endswith(".html"):
            raise SocialStoreError("Medium recognized archive members must be HTML")
        member_payload, document = documents[name]
        _parse_category_member(builder, category, name, member_payload, document)
        progress.present.add(category)
        progress.recognized += 1
    return progress


def _add_category_coverage(
    builder: MediumArchiveBuilder, present: set[str]
) -> None:
    for category in CATEGORY_PREFIXES:
        status = "complete" if category in present else "unavailable"
        reason = None if category in present else "category_not_present_in_archive"
        builder.add_coverage(
            category, status, reason, exhausted=category in present
        )


def _add_gap_coverage(
    builder: MediumArchiveBuilder, progress: _ArchiveProgress
) -> None:
    posts_present = "posts" in progress.present
    builder.add_coverage(
        "responses",
        "partial" if posts_present else "unavailable",
        (
            "archive_posts_do_not_guarantee_a_response_discriminator"
            if posts_present
            else "posts_category_not_present_in_archive"
        ),
        exhausted=posts_present,
    )
    builder.add_coverage(
        "mentions_messages",
        "unavailable",
        "no_documented_medium_export_category",
        exhausted=False,
    )
    builder.add_coverage(
        "local_media",
        "unavailable",
        "local_media_schema_not_validated_and_network_hydration_is_disabled",
        exhausted=False,
    )
    has_unmapped = progress.unrecognized > 0
    builder.add_coverage(
        "unmapped_archive_members",
        "partial" if has_unmapped else "complete",
        "raw_members_preserved_without_normalization" if has_unmapped else None,
        exhausted=not has_unmapped,
    )


def build_medium_archive(
    request: MediumArchiveRequest,
) -> tuple[ParsedMediumArchive, bytes]:
    """Validate a native Medium ZIP and build provider-neutral records in memory."""
    validate_opaque(request.connection_id, "connection_id")
    payload = read_regular_archive(request.path, request.max_bytes)
    digest = hashlib.sha256(payload).hexdigest()
    observed_at = normalize_exported_at(request.exported_at)
    contents = read_archive_contents(payload, request.max_bytes, request.max_items)
    profile = contents.documents.get("profile/profile.html")
    if profile is None:
        raise SocialStoreError(
            "Medium archive requires exactly one profile/profile.html"
        )
    identity = _profile_identity(profile[1])
    _validate_expected_identity(
        identity, request.expected_account_id, request.expected_username
    )
    builder = MediumArchiveBuilder(
        request.connection_id, identity, observed_at, digest, request.max_items
    )
    progress = _normalize_members(builder, contents)
    _add_category_coverage(builder, progress.present)
    _add_gap_coverage(builder, progress)
    parsed = builder.finish(
        progress.present, progress.recognized, progress.unrecognized
    )
    return parsed, payload
