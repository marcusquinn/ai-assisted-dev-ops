#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Identity, URL, timestamp, and provenance helpers for Medium exports."""

from __future__ import annotations

import hashlib
import re
from datetime import UTC, datetime
from typing import Any, Iterable
from urllib.parse import parse_qsl, urlsplit, urlunsplit

from _knowledge_social_medium_html import (
    HtmlNode,
    HtmlSelector,
    classes,
    descendants,
    first_descendant,
    text,
    walk,
)
from _knowledge_social_medium_types import MediumIdentity, PROVENANCE
from knowledge_source_contract import (
    FORBIDDEN_CREDENTIAL_KEYS,
    FORBIDDEN_CREDENTIAL_SUFFIXES,
)
from knowledge_social_store import SocialStoreError, validate_opaque

USER_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{2,127}$")
USERNAME = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
PROFILE_ID = re.compile(r"Medium user ID:\s*([A-Za-z0-9_-]{3,128})", re.I)
PROFILE_HANDLE = re.compile(r"^@([A-Za-z0-9_.-]{1,64})$", re.I)
PROFILE_TEXT_HANDLE = re.compile(r"Profile:\s*@([A-Za-z0-9_.-]{1,64})", re.I)
PROFILE_URL_HANDLE = re.compile(r"(?:^|/)@([A-Za-z0-9_.-]{1,64})(?:/|$)", re.I)
FORBIDDEN_URL_QUERY_KEYS = {
    "awsaccesskeyid",
    "googleaccessid",
    "keypairid",
    "policy",
    "sig",
    "signature",
}
FORBIDDEN_QUERY_KEYS = FORBIDDEN_CREDENTIAL_KEYS | FORBIDDEN_URL_QUERY_KEYS
FORBIDDEN_URL_QUERY_PREFIXES = ("xamz", "xgoog")
FORBIDDEN_URL_QUERY_SUFFIXES = (
    "accesskeyid",
    "credential",
    "keypairid",
    "securitytoken",
    "signature",
)


def _digest_id(prefix: str, *values: str) -> str:
    material = "\0".join(values).encode("utf-8")
    return f"{prefix}_{hashlib.sha256(material).hexdigest()[:40]}"


def _credential_query_key(normalized_key: str) -> bool:
    if normalized_key in FORBIDDEN_QUERY_KEYS:
        return True
    if normalized_key.startswith(FORBIDDEN_URL_QUERY_PREFIXES):
        return True
    return normalized_key.endswith(
        FORBIDDEN_CREDENTIAL_SUFFIXES + FORBIDDEN_URL_QUERY_SUFFIXES
    )


def _usable_url_value(value: str | None) -> bool:
    if not value:
        return False
    if "\x00" in value:
        return False
    return len(value.encode("utf-8")) <= 4096


def _normalized_url(value: str | None) -> str | None:
    if not _usable_url_value(value):
        return None
    if value is None:
        return None
    try:
        parsed = urlsplit(value)
        hostname = parsed.hostname
        port = parsed.port
    except ValueError as error:
        raise SocialStoreError("Medium archive URL is malformed") from error
    scheme = parsed.scheme.lower()
    if scheme not in {"http", "https"}:
        return None
    if not hostname:
        return None
    if parsed.username is not None:
        raise SocialStoreError("Medium archive URL contains user information")
    if parsed.password is not None:
        raise SocialStoreError("Medium archive URL contains user information")
    for key, _query_value in parse_qsl(
        parsed.query, keep_blank_values=True, max_num_fields=1000
    ):
        normalized_key = "".join(
            character for character in key.lower() if character.isalnum()
        )
        if _credential_query_key(normalized_key):
            raise SocialStoreError("Medium archive URL contains credential-shaped data")
    host = hostname.lower()
    if ":" in host:
        host = f"[{host}]"
    if port is not None:
        default = (scheme, port) in {("http", 80), ("https", 443)}
        if not default:
            host = f"{host}:{port}"
    return urlunsplit((scheme, host, parsed.path or "/", parsed.query, ""))


def _timestamp(value: str | None) -> tuple[str | None, str | None, bool]:
    if not isinstance(value, str):
        return None, None, False
    raw = value.strip()
    if not raw:
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

    profile_links = descendants(
        document, HtmlSelector(tag="a", class_name="u-url")
    )
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

    display = first_descendant(document, HtmlSelector(class_name="p-name"))
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
    if identity.username is None:
        raise SocialStoreError("selected Medium username does not match the archive")
    if identity.username.casefold() != selected.casefold():
        raise SocialStoreError("selected Medium username does not match the archive")


def _member_provenance(name: str, payload: bytes) -> dict[str, Any]:
    return {
        "source": PROVENANCE,
        "archive_member": name,
        "member_sha256": hashlib.sha256(payload).hexdigest(),
    }
