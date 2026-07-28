#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Shared records and bounded in-memory builder for Medium exports."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any

from knowledge_social_import import reject_credentials
from knowledge_social_store import SocialStoreError

PROVIDER = "medium"
ARCHIVE_SCHEMA = "medium-html-export-v1"
PROVENANCE = "medium_account_export"
RETENTION_LIMIT = "private_export_under_operator_control_and_lawful_purpose"

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
class MediumArchiveRequest:
    path: Path
    connection_id: str
    expected_account_id: str
    expected_username: str | None
    exported_at: str
    max_bytes: int
    max_items: int


@dataclass(frozen=True)
class MediumObjectRecord:
    object_type: str
    remote_id: str
    content: str | None
    created_at: str | None
    evidence_class: str
    provider_json: dict[str, Any]
    owned: bool = False


@dataclass(frozen=True)
class ParsedMediumArchive:
    archive: dict[str, Any]
    raw_sha256: str
    recognized_members: int
    unrecognized_members: int
    normalized_items: int


class MediumArchiveBuilder:
    """Accumulate provider-neutral records while enforcing the item budget."""

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

    def add_object(self, record: MediumObjectRecord) -> None:
        self.objects[(record.object_type, record.remote_id)] = {
            "object_type": record.object_type,
            "remote_id": record.remote_id,
            "account_remote_id": self.identity.account_id if record.owned else None,
            "text": record.content,
            "created_at": record.created_at,
            "observed_at": self.observed_at,
            "evidence_class": record.evidence_class,
            "provider_json": record.provider_json,
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
        archive = {
            "provider": PROVIDER,
            "connection_id": self.connection_id,
            "remote_account_id": self.identity.account_id,
            "exported_at": self.observed_at,
            "enabled_streams": sorted(present),
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
