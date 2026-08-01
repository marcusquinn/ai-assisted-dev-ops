#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Strict parser for bounded, user-authorized WhatsApp chat exports."""

from __future__ import annotations

import hashlib
import io
import mimetypes
import re
import time
from collections import Counter
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path, PurePosixPath
from typing import Any

from _knowledge_social_whatsapp_contract import (
    EXPORT_RETENTION,
    EXPORT_SCHEMA,
    ParsedWhatsAppBatch,
    account_record,
    alias_id,
    coverage_record,
    digest_id,
    finish_batch,
    fixed_timezone,
    normalized_observed_at,
)
from _knowledge_social_whatsapp_export_archive import (
    ExportContents,
    _check_deadline,
    _read_contents,
)
from knowledge_social_store import SocialStoreError

MAX_LINE_CHARS = 1024 * 1024
FORMAT_SPECS = {
    "android-us-12h": (re.compile(r"^(?P<date>\d{1,2}/\d{1,2}/\d{2,4}), (?P<time>\d{1,2}:\d{2}(?::\d{2})? [AP]M) - (?P<body>.*)$"), "%m/%d/%y %I:%M %p", "%m/%d/%Y %I:%M %p"),
    "android-dmy-24h": (re.compile(r"^(?P<date>\d{1,2}/\d{1,2}/\d{2,4}), (?P<time>\d{1,2}:\d{2}(?::\d{2})?) - (?P<body>.*)$"), "%d/%m/%y %H:%M", "%d/%m/%Y %H:%M"),
    "ios-us-12h": (re.compile(r"^\[(?P<date>\d{1,2}/\d{1,2}/\d{2,4}), (?P<time>\d{1,2}:\d{2}(?::\d{2})? [AP]M)\] (?P<body>.*)$"), "%m/%d/%y %I:%M %p", "%m/%d/%Y %I:%M %p"),
    "ios-dmy-24h": (re.compile(r"^\[(?P<date>\d{1,2}/\d{1,2}/\d{2,4}), (?P<time>\d{1,2}:\d{2}(?::\d{2})?)\] (?P<body>.*)$"), "%d/%m/%y %H:%M", "%d/%m/%Y %H:%M"),
}
ATTACHMENT_PATTERNS = (
    re.compile(r"^<attached: (?P<name>[^<>]+)>$", re.IGNORECASE),
    re.compile(r"^(?P<name>.+?) \(file attached\)$", re.IGNORECASE),
)
TIMESTAMP_LIKE = re.compile(r"^\[?\d{1,2}/\d{1,2}/\d{2,4}, ")


@dataclass(frozen=True)
class ExportRequest:
    path: Path
    connection_id: str
    conversation_id: str
    format_name: str
    timezone_name: str
    exported_at: str
    max_bytes: int
    max_items: int
    max_seconds: int


def _timestamp(date_value: str, time_value: str, format_name: str, zone: Any) -> str:
    _pattern, short_format, long_format = FORMAT_SPECS[format_name]
    parse_format = long_format if len(date_value.rsplit("/", 1)[-1]) == 4 else short_format
    if time_value.count(":") == 2:
        parse_format = parse_format.replace("%M", "%M:%S", 1)
    try:
        parsed = datetime.strptime(f"{date_value} {time_value}", parse_format)
    except ValueError as error:
        raise SocialStoreError("WhatsApp transcript timestamp does not match the selected format") from error
    if parsed.year < 2000:
        raise SocialStoreError("WhatsApp transcript contains an ambiguous two-digit year")
    return parsed.replace(tzinfo=zone).isoformat()


def _decode_transcript(transcript: bytes) -> str:
    try:
        return transcript.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise SocialStoreError("WhatsApp transcript must be UTF-8") from error


def _new_message(
    raw_line: str, pattern: re.Pattern[str], format_name: str, zone: Any
) -> tuple[str, str] | None:
    if len(raw_line) > MAX_LINE_CHARS:
        raise SocialStoreError("WhatsApp transcript line exceeds the character budget")
    normalized = raw_line.replace("\u202f", " ").replace("\u00a0", " ").lstrip("\u200e")
    match = pattern.match(normalized)
    if match:
        return _timestamp(match["date"], match["time"], format_name, zone), match["body"]
    if TIMESTAMP_LIKE.match(normalized):
        raise SocialStoreError("WhatsApp transcript mixes timestamp or locale formats")
    return None


def _append_continuation(current: tuple[str, str] | None, raw_line: str) -> tuple[str, str] | None:
    if current is not None:
        return current[0], f"{current[1]}\n{raw_line}"
    if raw_line.strip():
        raise SocialStoreError("WhatsApp transcript starts with an unrecognized line")
    return None


def _message_rows(
    transcript: bytes,
    format_name: str,
    zone: Any,
    max_items: int,
    deadline: float,
) -> list[tuple[str, str]]:
    pattern = FORMAT_SPECS[format_name][0]
    rows: list[tuple[str, str]] = []
    current: tuple[str, str] | None = None
    for raw_line in io.StringIO(_decode_transcript(transcript)):
        _check_deadline(deadline)
        raw_line = raw_line.rstrip("\r\n")
        candidate = _new_message(raw_line, pattern, format_name, zone)
        if candidate is not None:
            if current is not None:
                rows.append(current)
            current = candidate
        else:
            current = _append_continuation(current, raw_line)
        if len(rows) >= max_items:
            raise SocialStoreError("WhatsApp transcript exceeds the item budget")
    if current is not None:
        rows.append(current)
    if not rows:
        raise SocialStoreError("WhatsApp transcript contains no recognized records")
    return rows


def _attachment_name(content: str) -> str | None:
    for pattern in ATTACHMENT_PATTERNS:
        match = pattern.match(content.strip())
        if match:
            name = PurePosixPath(match["name"]).name
            return name if name == match["name"] else None
    return None


@dataclass
class _NormalizedExport:
    request: ExportRequest
    observed_at: str
    contents: ExportContents
    occurrences: Counter[tuple[str, str, str]] = field(default_factory=Counter)
    accounts: dict[str, dict[str, Any]] = field(default_factory=dict)
    objects: list[dict[str, Any]] = field(default_factory=list)
    media: list[dict[str, Any]] = field(default_factory=list)
    missing_media: int = 0

    def add(self, timestamp: str, body: str) -> None:
        sender, separator, content = body.partition(": ")
        actor_id = alias_id(sender, self.request.conversation_id) if separator else digest_id("system", self.request.conversation_id)
        if separator:
            self.accounts[actor_id] = account_record(actor_id, sender, self.observed_at, "unverified_export_alias")
        text = content if separator else body
        key = (timestamp, actor_id, text)
        ordinal = self.occurrences[key]
        self.occurrences[key] += 1
        content_digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        remote_id = digest_id("export-message", self.request.conversation_id, timestamp, actor_id, str(ordinal), content_digest)
        provider_json: dict[str, Any] = {
            "conversation_id": self.request.conversation_id,
            "identity_basis": "conversation_timestamp_sender_ordinal_content_digest",
            "occurrence_ordinal": ordinal,
            "parser_schema": EXPORT_SCHEMA,
            "attribution_status": "syntactic_alias_unverified" if separator else "unattributed",
            "record_kind": "message_like_record" if separator else "system_notice",
        }
        self._add_attachment(_attachment_name(text), remote_id, provider_json)
        self.objects.append({
            "object_type": "chat_message", "remote_id": remote_id,
            "account_remote_id": actor_id, "text": text, "created_at": timestamp,
            "observed_at": self.observed_at, "evidence_class": "observed",
            "provider_json": provider_json,
        })

    def _add_attachment(
        self, attachment: str | None, remote_id: str, provider_json: dict[str, Any]
    ) -> None:
        if not attachment:
            return
        matched = self.contents.media.get(attachment.casefold())
        if matched is None:
            self.missing_media += 1
            provider_json["attachment_state"] = "missing_from_archive"
            return
        member_name, media_digest, media_size = matched
        media_id = digest_id("export-media", self.request.conversation_id, remote_id, media_digest)
        provider_json["attachment_remote_id"] = media_id
        self.media.append({
            "remote_id": media_id, "object_remote_id": remote_id,
            "content_sha256": media_digest,
            "mime_type": mimetypes.guess_type(attachment)[0] or "application/octet-stream",
            "byte_size": media_size,
            "blob_ref": f"archive:{self.contents.raw_sha256}#{member_name}",
            "hydration_state": "embedded_in_raw_archive",
        })


def _export_coverage(
    observed_at: str, earliest: str, latest: str, missing_media: int
) -> list[dict[str, Any]]:
    coverage = [
        coverage_record("export_text", observed_at, EXPORT_RETENTION, "complete", reason=None, exhausted=True, earliest_at=earliest, latest_at=latest),
        coverage_record("participants", observed_at, EXPORT_RETENTION, "partial", reason="exports_expose_display_aliases_not_stable_provider_identity", exhausted=True),
        coverage_record("timestamps", observed_at, EXPORT_RETENTION, "partial", reason="fixed_offset_is_user_asserted_and_exports_spanning_dst_require_separate_imports", exhausted=True, earliest_at=earliest, latest_at=latest),
        coverage_record("attachments", observed_at, EXPORT_RETENTION, "partial" if missing_media else "complete", reason="referenced_media_missing_from_archive" if missing_media else None, exhausted=missing_media == 0),
    ]
    unavailable = (
        ("replies_quotes", "export_has_no_documented_structured_reply_schema"),
        ("edits_deletions", "export_has_no_documented_complete_edit_or_delete_history"),
        ("reactions", "export_has_no_documented_structured_reaction_schema"),
        ("history_before_export_window", "manual_export_limits_do_not_guarantee_complete_history"),
    )
    coverage.extend(
        coverage_record(stream, observed_at, EXPORT_RETENTION, "unavailable", reason=reason, exhausted=False)
        for stream, reason in unavailable
    )
    return coverage


def parse_export(request: ExportRequest) -> tuple[ParsedWhatsAppBatch, bytes]:
    if request.format_name not in FORMAT_SPECS:
        raise SocialStoreError("WhatsApp transcript format must be selected explicitly")
    if request.max_seconds < 1:
        raise SocialStoreError("WhatsApp elapsed-time budget must be positive")
    deadline = time.monotonic() + request.max_seconds
    observed_at = normalized_observed_at(request.exported_at)
    contents = _read_contents(
        request.path, request.max_bytes, request.max_items, deadline
    )
    rows = _message_rows(
        contents.transcript,
        request.format_name,
        fixed_timezone(request.timezone_name),
        request.max_items,
        deadline,
    )
    earliest = min(timestamp for timestamp, _body in rows)
    latest = max(timestamp for timestamp, _body in rows)
    normalized = _NormalizedExport(request, observed_at, contents)
    for timestamp, body in rows:
        _check_deadline(deadline)
        normalized.add(timestamp, body)
    parsed = finish_batch(
        connection_id=request.connection_id,
        remote_account_id=request.conversation_id,
        observed_at=observed_at,
        raw_sha256=contents.raw_sha256,
        stream="export",
        schema=EXPORT_SCHEMA,
        accounts=list(normalized.accounts.values()),
        objects=normalized.objects,
        activities=[],
        media=normalized.media,
        coverage=_export_coverage(observed_at, earliest, latest, normalized.missing_media),
        policy={"format": request.format_name, "timezone": request.timezone_name, "source": "user_authorized_chat_export"},
    )
    return parsed, contents.raw
