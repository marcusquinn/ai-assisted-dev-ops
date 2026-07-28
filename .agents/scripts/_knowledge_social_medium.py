#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validate, normalize, and atomically persist a Medium account export."""

from __future__ import annotations

import gzip
import hashlib
import io
import os
import re
import sqlite3
import stat
import zipfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Any, Iterable
from urllib.parse import parse_qsl, urlsplit, urlunsplit

from _knowledge_social_lease import (
    RunLease,
    RunReceiptUpdate,
    assert_run_lease,
    update_run_receipt,
)
from _knowledge_social_medium_html import (
    HtmlNode,
    classes,
    descendants,
    first_descendant,
    parse_html,
    text,
    walk,
)
from knowledge_social_import import (
    FORBIDDEN_CREDENTIAL_KEYS,
    FORBIDDEN_CREDENTIAL_SUFFIXES,
    import_accounts,
    import_activities,
    import_coverage,
    import_media,
    import_objects,
    reject_credentials,
    upsert_connection,
)
from knowledge_social_store import (
    SocialStoreError,
    connect,
    migrate,
    validate_opaque,
    write_raw_batch,
)

PROVIDER = "medium"
ARCHIVE_SCHEMA = "medium-html-export-v1"
PROVENANCE = "medium_account_export"
RETENTION_LIMIT = "private_export_under_operator_control_and_lawful_purpose"
MAX_MEMBER_BYTES = 32 * 1024 * 1024
USER_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
USERNAME = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
PROFILE_ID = re.compile(r"Medium user ID:\s*([A-Za-z0-9_-]{3,128})", re.I)
PROFILE_HANDLE = re.compile(r"^@([A-Za-z0-9_.-]{1,64})$", re.I)
PROFILE_TEXT_HANDLE = re.compile(r"Profile:\s*@([A-Za-z0-9_.-]{1,64})", re.I)
PROFILE_URL_HANDLE = re.compile(r"(?:^|/)@([A-Za-z0-9_.-]{1,64})(?:/|$)", re.I)
CLAP_COUNT = re.compile(r"\+(\d{1,3})\s*(?:—|-)")
FORBIDDEN_URL_QUERY_KEYS = {
    "awsaccesskeyid",
    "googleaccessid",
    "keypairid",
    "policy",
    "sig",
    "signature",
}
FORBIDDEN_URL_QUERY_PREFIXES = ("xamz", "xgoog")
FORBIDDEN_URL_QUERY_SUFFIXES = (
    "accesskeyid",
    "credential",
    "keypairid",
    "securitytoken",
    "signature",
)

CATEGORY_PREFIXES = {
    "posts": ("posts/",),
    "bookmarks": ("bookmarks/",),
    "claps": ("claps/",),
    "highlights": ("highlights/",),
    "lists": ("lists/",),
    "publication_membership": ("profile/publications.html",),
    "users_following": ("users-following/",),
    "publications_following": ("pubs-following/",),
    "topics_following": ("topics-following/",),
}


@dataclass(frozen=True)
class MediumIdentity:
    account_id: str
    username: str | None
    display_name: str | None
    profile_url: str | None


@dataclass(frozen=True)
class ParsedMediumArchive:
    archive: dict[str, Any]
    raw_sha256: str
    recognized_members: int
    unrecognized_members: int
    normalized_items: int


class _Builder:
    def __init__(
        self,
        connection_id: str,
        identity: MediumIdentity,
        observed_at: str,
        raw_sha256: str,
        max_items: int,
    ) -> None:
        self.connection_id = connection_id
        self.identity = identity
        self.observed_at = observed_at
        self.raw_sha256 = raw_sha256
        self.max_items = max_items
        self.accounts: dict[str, dict[str, Any]] = {}
        self.objects: dict[tuple[str, str], dict[str, Any]] = {}
        self.activities: dict[tuple[str, str], dict[str, Any]] = {}
        self.coverage: dict[str, dict[str, Any]] = {}
        self.add_account(
            identity.account_id,
            identity.username,
            identity.display_name,
            {
                "source": PROVENANCE,
                "profile_url": identity.profile_url,
                "identity_status": "verified",
            },
        )

    def _check_budget(self) -> None:
        count = len(self.accounts) + len(self.objects) + len(self.activities)
        if count > self.max_items:
            raise SocialStoreError("Medium archive exceeds the item budget")

    def add_account(
        self,
        remote_id: str,
        handle: str | None,
        display_name: str | None,
        provider_json: dict[str, Any],
    ) -> None:
        self.accounts[remote_id] = {
            "remote_id": remote_id,
            "handle": handle,
            "display_name": display_name,
            "observed_at": self.observed_at,
            "provider_json": provider_json,
        }
        self._check_budget()

    def add_object(
        self,
        object_type: str,
        remote_id: str,
        content: str | None,
        created_at: str | None,
        evidence_class: str,
        provider_json: dict[str, Any],
        *,
        owned: bool = False,
    ) -> None:
        self.objects[(object_type, remote_id)] = {
            "object_type": object_type,
            "remote_id": remote_id,
            "account_remote_id": self.identity.account_id if owned else None,
            "text": content,
            "created_at": created_at,
            "observed_at": self.observed_at,
            "evidence_class": evidence_class,
            "provider_json": provider_json,
        }
        self._check_budget()

    def add_activity(
        self,
        activity_type: str,
        remote_id: str,
        object_remote_id: str | None,
        occurred_at: str | None,
        provider_json: dict[str, Any],
    ) -> None:
        self.activities[(activity_type, remote_id)] = {
            "activity_type": activity_type,
            "remote_id": remote_id,
            "actor_remote_id": self.identity.account_id,
            "object_remote_id": object_remote_id,
            "occurred_at": occurred_at,
            "observed_at": self.observed_at,
            "state": "active",
            "provider_json": provider_json,
        }
        self._check_budget()

    def add_coverage(
        self,
        stream: str,
        status: str,
        reason: str | None,
        *,
        exhausted: bool,
    ) -> None:
        self.coverage[stream] = {
            "stream": stream,
            "earliest_at": None,
            "latest_at": None,
            "cursor_exhausted": exhausted,
            "retention_limit": RETENTION_LIMIT,
            "unavailable_reason": reason,
            "status": status,
            "observed_at": self.observed_at,
        }

    def finish(
        self, present: set[str], recognized: int, unrecognized: int
    ) -> ParsedMediumArchive:
        enabled = sorted(present)
        archive = {
            "provider": PROVIDER,
            "connection_id": self.connection_id,
            "remote_account_id": self.identity.account_id,
            "exported_at": self.observed_at,
            "enabled_streams": enabled,
            "policy": {
                "archive_schema": ARCHIVE_SCHEMA,
                "archive_sha256": self.raw_sha256,
                "network_requests": 0,
                "recognized_members": recognized,
                "unrecognized_members": unrecognized,
                "source": PROVENANCE,
            },
            "accounts": sorted(self.accounts.values(), key=lambda row: row["remote_id"]),
            "objects": sorted(
                self.objects.values(),
                key=lambda row: (row["object_type"], row["remote_id"]),
            ),
            "activities": sorted(
                self.activities.values(),
                key=lambda row: (row["activity_type"], row["remote_id"]),
            ),
            "media": [],
            "coverage": sorted(self.coverage.values(), key=lambda row: row["stream"]),
        }
        reject_credentials(archive)
        normalized_items = (
            len(archive["accounts"])
            + len(archive["objects"])
            + len(archive["activities"])
        )
        return ParsedMediumArchive(
            archive, self.raw_sha256, recognized, unrecognized, normalized_items
        )


def _digest_id(prefix: str, *values: str) -> str:
    material = "\0".join(values).encode("utf-8")
    return f"{prefix}_{hashlib.sha256(material).hexdigest()[:40]}"


def _normalized_url(value: str | None) -> str | None:
    if not value or "\x00" in value or len(value.encode("utf-8")) > 4096:
        return None
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as error:
        raise SocialStoreError("Medium archive URL is malformed") from error
    if parsed.scheme.lower() not in {"http", "https"} or not hostname:
        return None
    if parsed.username is not None or parsed.password is not None:
        raise SocialStoreError("Medium archive URL contains user information")
    for key, _query_value in parse_qsl(
        parsed.query, keep_blank_values=True, max_num_fields=1000
    ):
        normalized_key = "".join(
            character for character in key.lower() if character.isalnum()
        )
        if (
            normalized_key in FORBIDDEN_CREDENTIAL_KEYS
            or normalized_key in FORBIDDEN_URL_QUERY_KEYS
            or normalized_key.startswith(FORBIDDEN_URL_QUERY_PREFIXES)
            or normalized_key.endswith(FORBIDDEN_CREDENTIAL_SUFFIXES)
            or normalized_key.endswith(FORBIDDEN_URL_QUERY_SUFFIXES)
        ):
            raise SocialStoreError("Medium archive URL contains credential-shaped data")
    host = hostname.lower()
    if ":" in host:
        host = f"[{host}]"
    if port is not None:
        default = (parsed.scheme.lower(), port) in {("http", 80), ("https", 443)}
        if not default:
            host = f"{host}:{port}"
    path = parsed.path or "/"
    return urlunsplit((parsed.scheme.lower(), host, path, parsed.query, ""))


def _timestamp(value: str | None) -> tuple[str | None, str | None, bool]:
    raw = value.strip() if isinstance(value, str) and value.strip() else None
    if raw is None:
        return None, None, False
    try:
        parsed = datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError:
        return None, raw, False
    if parsed.tzinfo is None:
        return None, raw, False
    normalized = parsed.astimezone(UTC).isoformat().replace("+00:00", "Z")
    return normalized, raw, True


def normalize_exported_at(value: str) -> str:
    normalized, _raw, known = _timestamp(value)
    if not known or normalized is None:
        raise SocialStoreError("Medium exported-at must include an explicit timezone")
    return normalized


def _node_href(node: HtmlNode | None) -> str | None:
    return _normalized_url(node.attrs.get("href")) if node is not None else None


def _first_with_classes(node: HtmlNode, names: Iterable[str]) -> HtmlNode | None:
    expected = set(names)
    for candidate in walk(node):
        if expected.intersection(classes(candidate)):
            return candidate
    return None


def _profile_identity(document: HtmlNode) -> MediumIdentity:
    content = text(document)
    identifiers = set(PROFILE_ID.findall(content))
    if len(identifiers) != 1:
        raise SocialStoreError(
            "Medium archive requires exactly one profile Medium user ID"
        )
    account_id = next(iter(identifiers))
    if USER_ID.fullmatch(account_id) is None:
        raise SocialStoreError("Medium archive profile user ID is invalid")

    profile_links = descendants(document, tag="a", class_name="u-url")
    profile_urls = {_node_href(node) for node in profile_links}
    profile_urls.discard(None)
    if len(profile_urls) > 1:
        raise SocialStoreError("Medium archive profile URLs conflict")
    profile_url = next(iter(profile_urls), None)

    handles: set[str] = set()
    for node in profile_links:
        label_match = PROFILE_HANDLE.fullmatch(text(node))
        url_match = PROFILE_URL_HANDLE.search(node.attrs.get("href", ""))
        if label_match:
            handles.add(label_match.group(1))
        if url_match:
            handles.add(url_match.group(1))
    profile_match = PROFILE_TEXT_HANDLE.search(content)
    if profile_match:
        handles.add(profile_match.group(1))
    if len({handle.casefold() for handle in handles}) > 1:
        raise SocialStoreError("Medium archive profile usernames conflict")
    username = next(iter(handles), None)
    if username is not None and USERNAME.fullmatch(username) is None:
        raise SocialStoreError("Medium archive profile username is invalid")

    display = first_descendant(document, class_name="p-name")
    display_name = text(display) if display is not None else None
    return MediumIdentity(account_id, username, display_name or None, profile_url)


def _validate_expected_identity(
    identity: MediumIdentity, expected_account_id: str, expected_username: str | None
) -> None:
    validate_opaque(expected_account_id, "account_id")
    if identity.account_id != expected_account_id:
        raise SocialStoreError("selected Medium account does not match the archive")
    if expected_username is None:
        return
    selected = expected_username.removeprefix("@")
    if USERNAME.fullmatch(selected) is None:
        raise SocialStoreError("selected Medium username is invalid")
    if identity.username is None or identity.username.casefold() != selected.casefold():
        raise SocialStoreError("selected Medium username does not match the archive")


def _member_provenance(name: str, payload: bytes) -> dict[str, Any]:
    return {
        "source": PROVENANCE,
        "archive_member": name,
        "member_sha256": hashlib.sha256(payload).hexdigest(),
    }


def _post(
    builder: _Builder, name: str, payload: bytes, document: HtmlNode
) -> int:
    body = first_descendant(document, attr_name="data-field", attr_value="body")
    if body is None:
        body = first_descendant(document, class_name="e-content")
    if body is None:
        raise SocialStoreError("Medium archive post is missing its body marker")
    title_node = first_descendant(document, class_name="p-name")
    if title_node is None:
        title_node = first_descendant(document, tag="title")
    title = text(title_node) if title_node is not None else ""
    body_text = text(body)
    content = "\n\n".join(part for part in (title, body_text) if part) or None

    canonical_nodes = descendants(document, tag="a", class_name="p-canonical")
    canonical_urls = {_node_href(node) for node in canonical_nodes}
    canonical_urls.discard(None)
    if len(canonical_urls) > 1:
        raise SocialStoreError("Medium archive post canonical URLs conflict")
    canonical_url = next(iter(canonical_urls), None)

    author_nodes = descendants(document, tag="a", class_name="p-author")
    author_handles: set[str] = set()
    for node in author_nodes:
        label_match = PROFILE_HANDLE.fullmatch(text(node))
        url_match = PROFILE_URL_HANDLE.search(node.attrs.get("href", ""))
        if label_match:
            author_handles.add(label_match.group(1))
        if url_match:
            author_handles.add(url_match.group(1))
    if (
        builder.identity.username is not None
        and author_handles
        and builder.identity.username.casefold()
        not in {handle.casefold() for handle in author_handles}
    ):
        raise SocialStoreError("Medium archive post author conflicts with the profile")

    published = first_descendant(document, tag="time", class_name="dt-published")
    published_value = (
        published.attrs.get("datetime") or text(published) if published is not None else None
    )
    occurred_at, timestamp_raw, timezone_known = _timestamp(published_value)
    response_marker = any(
        "u-in-reply-to" in classes(node) or "data-response-id" in node.attrs
        for node in walk(document)
    )
    explicit_ids = {
        node.attrs[attribute]
        for node in walk(document)
        for attribute in ("data-post-id", "data-response-id")
        if node.attrs.get(attribute)
    }
    if len(explicit_ids) > 1:
        raise SocialStoreError("Medium archive post IDs conflict")
    if explicit_ids:
        remote_id = _digest_id("medium_post", next(iter(explicit_ids)))
        identity_confidence = "explicit"
    elif canonical_url is not None:
        remote_id = _digest_id("medium_post", canonical_url)
        identity_confidence = "canonical_url"
    else:
        remote_id = _digest_id("medium_post", name, hashlib.sha256(payload).hexdigest())
        identity_confidence = "content_addressed"

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
        "post",
        remote_id,
        content,
        occurred_at,
        "authored",
        provenance,
        owned=True,
    )
    builder.add_activity(
        "content_author",
        _digest_id("medium_activity", builder.identity.account_id, remote_id),
        remote_id,
        occurred_at,
        {"source": PROVENANCE, "post_kind": provenance["post_kind"]},
    )
    return 1


def _reference_object(
    builder: _Builder, url: str, title: str | None, source: str
) -> str:
    remote_id = _digest_id("medium_url", url)
    builder.add_object(
        "story_reference",
        remote_id,
        title,
        None,
        "curated",
        {"source": PROVENANCE, "canonical_url": url, "archive_category": source},
    )
    return remote_id


def _time_from_item(item: HtmlNode) -> tuple[str | None, str | None, bool]:
    node = first_descendant(item, tag="time", class_name="dt-published")
    value = node.attrs.get("datetime") or text(node) if node is not None else None
    return _timestamp(value)


def _bookmarks(builder: _Builder, name: str, document: HtmlNode) -> int:
    items = descendants(document, tag="li")
    if not items and first_descendant(document, tag="ul") is None:
        raise SocialStoreError("Medium bookmark schema is unrecognized")
    processed = 0
    for item in items:
        anchor = first_descendant(item, tag="a", class_name="h-cite")
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
            {
                "source": PROVENANCE,
                "archive_member": name,
                "timestamp_raw": raw,
                "timestamp_timezone_known": known,
            },
        )
        processed += 1
    return processed


def _claps(builder: _Builder, name: str, document: HtmlNode) -> int:
    items = descendants(document, tag="li")
    if not items and first_descendant(document, tag="ul") is None:
        raise SocialStoreError("Medium clap schema is unrecognized")
    processed = 0
    for item in items:
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
        builder.add_activity(
            "clap",
            _digest_id("medium_clap", builder.identity.account_id, object_id),
            object_id,
            occurred_at,
            {
                "source": PROVENANCE,
                "archive_member": name,
                "clap_count": clap_count,
                "timestamp_raw": raw,
                "timestamp_timezone_known": known,
            },
        )
        processed += 1
    return processed


def _highlights(builder: _Builder, name: str, document: HtmlNode) -> int:
    items = descendants(document, tag="li")
    if not items and first_descendant(document, tag="ul") is None:
        raise SocialStoreError("Medium highlight schema is unrecognized")
    processed = 0
    for item_index, item in enumerate(items):
        source = _first_with_classes(item, ("h-cite", "u-highlight-of"))
        source_url = _node_href(source)
        if source is not None and source_url is None:
            raise SocialStoreError("Medium highlight source URL is invalid")
        marked = descendants(item, class_name="markup--highlight")
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
            builder.add_object(
                "highlight",
                remote_id,
                selected_text,
                occurred_at,
                "curated",
                {
                    "source": PROVENANCE,
                    "archive_member": name,
                    "source_url": source_url,
                    "timestamp_raw": raw,
                    "timestamp_timezone_known": known,
                },
            )
            builder.add_activity(
                "highlight",
                _digest_id("medium_highlight_activity", builder.identity.account_id, remote_id),
                remote_id,
                occurred_at,
                {"source": PROVENANCE},
            )
            processed += 1
    return processed


def _lists(builder: _Builder, name: str, payload: bytes, document: HtmlNode) -> int:
    title_node = first_descendant(document, class_name="p-name")
    summary_node = first_descendant(document, class_name="p-summary")
    title = text(title_node) if title_node is not None else None
    summary = text(summary_node) if summary_node is not None else None
    canonical = first_descendant(document, tag="a", class_name="p-canonical")
    list_url = _node_href(canonical)
    if not title:
        raise SocialStoreError("Medium archive list is missing its title marker")
    list_id = (
        _digest_id("medium_list", list_url)
        if list_url is not None
        else _digest_id("medium_list", name, hashlib.sha256(payload).hexdigest())
    )
    builder.add_object(
        "list",
        list_id,
        "\n\n".join(value for value in (title, summary) if value) or None,
        None,
        "curated",
        {
            **_member_provenance(name, payload),
            "canonical_url": list_url,
        },
        owned=True,
    )
    processed = 1
    for item in descendants(document, tag="li", attr_name="data-field", attr_value="post"):
        anchor = first_descendant(item, tag="a", attr_name="href")
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


def _profile_publications(builder: _Builder, document: HtmlNode) -> int:
    if first_descendant(document, tag="ul") is None:
        raise SocialStoreError("Medium publication membership schema is unrecognized")
    processed = 0
    for anchor in descendants(document, tag="a", attr_name="href"):
        url = _node_href(anchor)
        label = text(anchor)
        if url is None or not label:
            raise SocialStoreError("Medium publication membership URL is invalid")
        surrounding = text(anchor)
        role = next(
            (value for value in ("editor", "writer") if value in surrounding.casefold()),
            "member",
        )
        publication_id = _digest_id("medium_publication", url)
        builder.add_object(
            "publication",
            publication_id,
            label,
            None,
            "relationship",
            {"source": PROVENANCE, "canonical_url": url},
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


def _following(builder: _Builder, category: str, document: HtmlNode) -> int:
    target_type = {
        "users_following": "user",
        "publications_following": "publication",
        "topics_following": "topic",
    }[category]
    anchors = descendants(document, tag="a", attr_name="href")
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
                target_type,
                target_id,
                label,
                None,
                "relationship",
                {"source": PROVENANCE, "canonical_url": url},
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


def _category(name: str) -> str | None:
    for category, prefixes in CATEGORY_PREFIXES.items():
        if any(name == prefix or name.startswith(prefix) for prefix in prefixes):
            return category
    return None


def _safe_members(
    archive: zipfile.ZipFile, max_bytes: int, max_items: int
) -> list[zipfile.ZipInfo]:
    infos = archive.infolist()
    if len(infos) > max_items:
        raise SocialStoreError("Medium archive exceeds the member budget")
    seen: set[str] = set()
    folded: set[str] = set()
    total = 0
    safe: list[zipfile.ZipInfo] = []
    for info in infos:
        name = info.filename
        path = PurePosixPath(name)
        if (
            not name
            or "\\" in name
            or "\x00" in name
            or path.is_absolute()
            or any(part in {"", ".", ".."} for part in path.parts)
        ):
            raise SocialStoreError("Medium archive contains an unsafe member path")
        if name in seen or name.casefold() in folded:
            raise SocialStoreError("Medium archive contains duplicate member paths")
        seen.add(name)
        folded.add(name.casefold())
        mode = (info.external_attr >> 16) & 0o170000
        if mode == stat.S_IFLNK:
            raise SocialStoreError("Medium archive cannot contain symbolic links")
        if info.flag_bits & 0x1:
            raise SocialStoreError("Medium archive cannot contain encrypted members")
        if info.is_dir():
            continue
        if info.file_size > MAX_MEMBER_BYTES:
            raise SocialStoreError("Medium archive member exceeds the byte budget")
        total += info.file_size
        if total > max_bytes:
            raise SocialStoreError("Medium archive exceeds the uncompressed byte budget")
        safe.append(info)
    return sorted(safe, key=lambda info: info.filename)


def _read_regular_archive(path: Path, max_bytes: int) -> bytes:
    """Open once without following symlinks and reject in-place changes."""
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    if nofollow:
        flags |= nofollow
    elif path.is_symlink():
        raise SocialStoreError("Medium archive must be a regular non-symlink file")
    descriptor = -1
    try:
        descriptor = os.open(path, flags)
        with os.fdopen(descriptor, "rb") as source:
            descriptor = -1
            before = os.fstat(source.fileno())
            if not stat.S_ISREG(before.st_mode):
                raise SocialStoreError(
                    "Medium archive must be a regular non-symlink file"
                )
            if before.st_size <= 0 or before.st_size > max_bytes:
                raise SocialStoreError(
                    "Medium archive exceeds the compressed byte budget"
                )
            payload = source.read(max_bytes + 1)
            after = os.fstat(source.fileno())
    except SocialStoreError:
        raise
    except OSError as error:
        raise SocialStoreError("Medium archive could not be opened safely") from error
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    before_identity = (
        before.st_dev,
        before.st_ino,
        before.st_size,
        before.st_mtime_ns,
    )
    after_identity = (
        after.st_dev,
        after.st_ino,
        after.st_size,
        after.st_mtime_ns,
    )
    if (
        len(payload) > max_bytes
        or len(payload) != before.st_size
        or before_identity != after_identity
    ):
        raise SocialStoreError("Medium archive changed while it was being read")
    return payload


def _parse_category_member(
    builder: _Builder,
    category: str,
    name: str,
    payload: bytes,
    document: HtmlNode,
) -> int:
    if category == "posts":
        return _post(builder, name, payload, document)
    if category == "bookmarks":
        return _bookmarks(builder, name, document)
    if category == "claps":
        return _claps(builder, name, document)
    if category == "highlights":
        return _highlights(builder, name, document)
    if category == "lists":
        return _lists(builder, name, payload, document)
    if category == "publication_membership":
        return _profile_publications(builder, document)
    return _following(builder, category, document)


def parse_medium_archive(
    path: Path,
    connection_id: str,
    expected_account_id: str,
    expected_username: str | None,
    exported_at: str,
    max_bytes: int,
    max_items: int,
) -> tuple[ParsedMediumArchive, bytes]:
    """Validate a native Medium ZIP and build provider-neutral records in memory."""
    validate_opaque(connection_id, "connection_id")
    payload = _read_regular_archive(path, max_bytes)
    digest = hashlib.sha256(payload).hexdigest()
    observed_at = normalize_exported_at(exported_at)
    try:
        with zipfile.ZipFile(io.BytesIO(payload), "r") as archive:
            members = _safe_members(archive, max_bytes, max_items)
            profile_infos = [
                info for info in members if info.filename == "profile/profile.html"
            ]
            if len(profile_infos) != 1:
                raise SocialStoreError(
                    "Medium archive requires exactly one profile/profile.html"
                )
            documents: dict[str, tuple[bytes, HtmlNode]] = {}
            for info in members:
                if not info.filename.lower().endswith(".html"):
                    continue
                member_payload = archive.read(info)
                documents[info.filename] = (member_payload, parse_html(member_payload))
    except (
        RecursionError,
        RuntimeError,
        zipfile.BadZipFile,
        zipfile.LargeZipFile,
    ) as error:
        raise SocialStoreError("Medium archive is not a supported ZIP file") from error

    identity = _profile_identity(documents["profile/profile.html"][1])
    _validate_expected_identity(identity, expected_account_id, expected_username)
    builder = _Builder(
        connection_id, identity, observed_at, digest, max_items
    )
    present: set[str] = set()
    recognized = 1
    unrecognized = 0
    for info in members:
        name = info.filename
        if name == "profile/profile.html":
            continue
        category = _category(name)
        if category is None:
            unrecognized += 1
            continue
        if not name.lower().endswith(".html"):
            raise SocialStoreError("Medium recognized archive members must be HTML")
        member_payload, document = documents[name]
        _parse_category_member(builder, category, name, member_payload, document)
        present.add(category)
        recognized += 1

    for category in CATEGORY_PREFIXES:
        status = "complete" if category in present else "unavailable"
        reason = None if category in present else "category_not_present_in_archive"
        builder.add_coverage(
            category, status, reason, exhausted=category in present
        )
    builder.add_coverage(
        "responses",
        "partial" if "posts" in present else "unavailable",
        (
            "archive_posts_do_not_guarantee_a_response_discriminator"
            if "posts" in present
            else "posts_category_not_present_in_archive"
        ),
        exhausted="posts" in present,
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
    builder.add_coverage(
        "unmapped_archive_members",
        "partial" if unrecognized else "complete",
        "raw_members_preserved_without_normalization" if unrecognized else None,
        exhausted=unrecognized == 0,
    )
    return builder.finish(present, recognized, unrecognized), payload


def _assert_connection_binding(
    database: sqlite3.Connection, connection_id: str, account_id: str
) -> None:
    row = database.execute(
        "SELECT provider,remote_account_id FROM connections WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is None:
        return
    if row["provider"] != PROVIDER or row["remote_account_id"] != account_id:
        raise SocialStoreError("Medium connection is already bound to another account")


def _refresh_fts(database: sqlite3.Connection, archive: dict[str, Any]) -> None:
    for record in archive["objects"]:
        identity = (PROVIDER, record["object_type"], record["remote_id"])
        database.execute(
            "DELETE FROM objects_fts WHERE provider=? AND object_type=? AND remote_id=?",
            identity,
        )
        database.execute(
            """INSERT INTO objects_fts(
               provider,object_type,remote_id,account_remote_id,text_content,evidence_class)
               SELECT provider,object_type,remote_id,account_remote_id,text_content,evidence_class
                 FROM objects WHERE provider=? AND object_type=? AND remote_id=?""",
            identity,
        )


def _raw_path(root: Path, connection_id: str, digest: str) -> Path:
    return (
        root
        / "sources"
        / "social"
        / "raw"
        / PROVIDER
        / connection_id
        / f"{digest}.json.gz"
    )


def _gzip_payload_digest(path: Path) -> str:
    if path.is_symlink() or not path.is_file():
        raise SocialStoreError("Medium raw evidence is missing or unsafe")
    digest = hashlib.sha256()
    try:
        with gzip.open(path, "rb") as source:
            while chunk := source.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise SocialStoreError("Medium raw evidence could not be verified") from error
    return digest.hexdigest()


def _validate_replay_blob(
    root: Path, connection_id: str, digest: str, blob_ref: str
) -> None:
    path = _raw_path(root, connection_id, digest)
    expected_ref = path.relative_to(root).as_posix()
    if blob_ref != expected_ref or _gzip_payload_digest(path) != digest:
        raise SocialStoreError("Medium raw replay evidence does not match its batch")


def _remove_created_raw(path: Path, digest: str) -> None:
    try:
        if _gzip_payload_digest(path) == digest:
            path.unlink()
    except (OSError, SocialStoreError):
        return


def _result(
    parsed: ParsedMediumArchive,
    account_id: str,
    blob_ref: str,
    normalized_items: int,
    *,
    replayed: bool,
) -> dict[str, Any]:
    return {
        "account_id": account_id,
        "archive_sha256": parsed.raw_sha256,
        "blob_ref": blob_ref,
        "normalized_items": normalized_items,
        "recognized_members": parsed.recognized_members,
        "replayed": replayed,
        "status": "complete",
        "unrecognized_members": parsed.unrecognized_members,
    }


def persist_medium_archive(
    root: Path,
    parsed: ParsedMediumArchive,
    payload: bytes,
    lease: RunLease,
) -> dict[str, Any]:
    """Commit raw ZIP evidence, normalized rows, coverage, and replay marker atomically."""
    archive = parsed.archive
    reject_credentials(archive)
    if hashlib.sha256(payload).hexdigest() != parsed.raw_sha256:
        raise SocialStoreError("Medium archive changed after validation")
    connection_id = archive["connection_id"]
    account_id = archive["remote_account_id"]
    raw_path = _raw_path(root, connection_id, parsed.raw_sha256)
    raw_existed = raw_path.exists() or raw_path.is_symlink()
    created_raw = False
    committed = False
    database = connect(root)
    try:
        migrate(database)
        database.execute("BEGIN IMMEDIATE")
        assert_run_lease(database, lease)
        _assert_connection_binding(database, connection_id, account_id)
        existing = database.execute(
            "SELECT provider,connection_id,stream,response_hash,blob_ref,"
            "resource_count,completed_at FROM fetch_batches WHERE batch_id=?",
            (parsed.raw_sha256,),
        ).fetchone()
        if existing is not None:
            if (
                existing["provider"] != PROVIDER
                or existing["connection_id"] != connection_id
            ):
                raise SocialStoreError(
                    "Medium archive digest is already bound to another connection"
                )
            if (
                existing["stream"] != "archive"
                or existing["response_hash"] != parsed.raw_sha256
                or existing["completed_at"] != archive["exported_at"]
            ):
                raise SocialStoreError(
                    "Medium archive replay metadata conflicts with the stored batch"
                )
            _validate_replay_blob(
                root,
                connection_id,
                parsed.raw_sha256,
                str(existing["blob_ref"]),
            )
            update_run_receipt(
                database,
                lease,
                RunReceiptUpdate("complete", resource_delta=0, terminal=True),
            )
            database.execute("COMMIT")
            committed = True
            return _result(
                parsed,
                account_id,
                str(existing["blob_ref"]),
                int(existing["resource_count"]),
                replayed=True,
            )
        batch_id, blob_ref = write_raw_batch(
            root, PROVIDER, connection_id, payload
        )
        created_raw = not raw_existed
        if batch_id != parsed.raw_sha256:
            raise SocialStoreError("Medium raw evidence hash changed")
        upsert_connection(database, archive, PROVIDER, connection_id)
        import_accounts(database, archive, PROVIDER)
        import_objects(database, archive, PROVIDER, batch_id)
        import_activities(database, archive, PROVIDER, batch_id)
        import_media(database, archive, PROVIDER, batch_id)
        import_coverage(database, archive, PROVIDER, connection_id, batch_id)
        _refresh_fts(database, archive)
        database.execute(
            """INSERT INTO fetch_batches(
               batch_id,provider,connection_id,stream,request_hash,response_hash,blob_ref,
               resource_count,budget_units,started_at,completed_at,terminal_status)
               VALUES(?,?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(batch_id) DO NOTHING""",
            (
                batch_id,
                PROVIDER,
                connection_id,
                "archive",
                batch_id,
                batch_id,
                blob_ref,
                parsed.normalized_items,
                0,
                archive["exported_at"],
                archive["exported_at"],
                "success",
            ),
        )
        database.execute(
            """INSERT INTO sync_cursors(
               connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
               VALUES(?,?,?,?,?,1) ON CONFLICT(connection_id,stream) DO UPDATE SET
               cursor=NULL,watermark=excluded.watermark,
               last_success_at=excluded.last_success_at,backfill_complete=1""",
            (connection_id, "archive", None, batch_id, archive["exported_at"]),
        )
        update_run_receipt(
            database,
            lease,
            RunReceiptUpdate(
                "complete", resource_delta=parsed.normalized_items, terminal=True
            ),
        )
        database.execute("COMMIT")
        committed = True
        return _result(
            parsed,
            account_id,
            blob_ref,
            parsed.normalized_items,
            replayed=False,
        )
    except Exception:
        if database.in_transaction:
            database.execute("ROLLBACK")
        if created_raw and not committed:
            _remove_created_raw(raw_path, parsed.raw_sha256)
        raise
    finally:
        database.close()
