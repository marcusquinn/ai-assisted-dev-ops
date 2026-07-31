#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Bounded parser for operator-supplied official Discord account exports."""

from __future__ import annotations

import csv
import io
import json
import re
import zipfile
from pathlib import Path, PurePosixPath
from typing import Any

from _knowledge_social_discord_contract import DiscordReadProviderError, snowflake, text

MAX_EXPORT_BYTES = 2 * 1024 * 1024 * 1024
MAX_ENTRY_BYTES = 64 * 1024 * 1024
MAX_ENTRIES = 100_000
MESSAGE_CSV = re.compile(r"^messages/[^/]+/messages\.csv$")


def _safe_names(archive: zipfile.ZipFile) -> list[str]:
    infos = archive.infolist()
    total_size = sum(info.file_size for info in infos)
    if len(infos) > MAX_ENTRIES or total_size > MAX_EXPORT_BYTES:
        raise DiscordReadProviderError("Discord account export exceeds the safety limit")
    names = []
    for info in infos:
        path = PurePosixPath(info.filename)
        if path.is_absolute() or ".." in path.parts or info.file_size > MAX_ENTRY_BYTES:
            raise DiscordReadProviderError("Discord account export contains an unsafe entry")
        names.append(info.filename)
    return names


def _verify_export_user(
    archive: zipfile.ZipFile, names: list[str], expected_user_id: str
) -> None:
    candidates = ("account/user.json", "account/account.json", "user.json")
    name = next((candidate for candidate in candidates if candidate in names), None)
    if name is None:
        raise DiscordReadProviderError("Discord account export user identity is missing")
    try:
        payload = json.loads(archive.read(name).decode("utf-8"))
    except (KeyError, UnicodeError, json.JSONDecodeError) as error:
        raise DiscordReadProviderError("Discord account export user is invalid") from error
    if not isinstance(payload, dict):
        raise DiscordReadProviderError("Discord account export user is invalid")
    exported_user_id = snowflake(
        payload.get("id") or payload.get("user_id"), "export user ID"
    )
    if exported_user_id != expected_user_id:
        raise DiscordReadProviderError("Discord account export user identity mismatched")


def _channel_ids(archive: zipfile.ZipFile, names: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for name in names:
        if not name.startswith("messages/") or not name.endswith("/channel.json"):
            continue
        try:
            payload = json.loads(archive.read(name).decode("utf-8"))
        except (KeyError, UnicodeError, json.JSONDecodeError) as error:
            raise DiscordReadProviderError("Discord account export channel is invalid") from error
        if not isinstance(payload, dict):
            raise DiscordReadProviderError("Discord account export channel is invalid")
        channel_id = snowflake(payload.get("id"), "export channel ID")
        result[str(PurePosixPath(name).parent / "messages.csv")] = channel_id or ""
    return result


def _message_row(
    row: dict[str, str | None], channel_id: str, author_id: str
) -> dict[str, Any]:
    return {
        "kind": "export_message",
        "remote_id": snowflake(row.get("ID") or row.get("id"), "export message ID"),
        "channel_id": channel_id,
        "author_id": author_id,
        "timestamp": text(
            row.get("Timestamp") or row.get("timestamp"),
            "export message timestamp",
        ),
        "content": text(
            row.get("Contents") or row.get("content") or "",
            "export message content",
        ),
        "attachments": text(
            row.get("Attachments") or row.get("attachments"),
            "export attachment references",
            optional=True,
        ),
    }


def _csv_rows(
    archive: zipfile.ZipFile, name: str, channel_id: str, author_id: str
) -> list[dict[str, Any]]:
    try:
        source = io.StringIO(archive.read(name).decode("utf-8-sig"), newline="")
        return [_message_row(row, channel_id, author_id) for row in csv.DictReader(source)]
    except (KeyError, OSError, UnicodeError, csv.Error) as error:
        raise DiscordReadProviderError("Discord account export messages are invalid") from error


def _rows(archive: zipfile.ZipFile, config: dict[str, Any]) -> list[dict[str, Any]]:
    names = _safe_names(archive)
    _verify_export_user(archive, names, config["export_user_id"])
    channels = _channel_ids(archive, names)
    allowed = {
        *config["channel_ids"],
        *config["thread_ids"],
        *config["dm_channel_ids"],
    }
    records: list[dict[str, Any]] = []
    for name in sorted(value for value in names if MESSAGE_CSV.fullmatch(value)):
        channel_id = channels.get(name)
        if channel_id not in allowed:
            continue
        records.extend(_csv_rows(archive, name, channel_id, config["export_user_id"]))
    return records


def _export_path(path_value: str | None) -> Path:
    if not path_value:
        raise DiscordReadProviderError("Discord account export is unavailable")
    path = Path(path_value).expanduser()
    valid = (
        not path.is_symlink()
        and path.is_file()
        and path.stat().st_size <= MAX_EXPORT_BYTES
        and zipfile.is_zipfile(path)
    )
    if not valid:
        raise DiscordReadProviderError("Discord account export is unavailable")
    return path


def _export_offset(cursor: dict[str, Any] | None) -> int:
    if cursor is None:
        return 0
    offset = cursor.get("offset")
    if set(cursor) != {"offset"} or isinstance(offset, bool) or not isinstance(offset, int):
        raise DiscordReadProviderError("Discord export cursor is invalid")
    if offset < 0:
        raise DiscordReadProviderError("Discord export cursor is invalid")
    return offset


def page_account_export(
    path_value: str | None,
    config: dict[str, Any],
    cursor: dict[str, Any] | None,
    limit: int,
) -> tuple[list[dict[str, Any]], dict[str, Any] | None]:
    """Page a validated export without treating it as a user-session credential."""
    if config.get("export_user_id") is None:
        raise DiscordReadProviderError("Discord account export is unavailable")
    path = _export_path(path_value)
    offset = _export_offset(cursor)
    try:
        with zipfile.ZipFile(path) as archive:
            rows = _rows(archive, config)
    except (OSError, zipfile.BadZipFile) as error:
        raise DiscordReadProviderError("Discord account export is invalid") from error
    page = rows[offset : offset + limit]
    next_offset = offset + len(page)
    next_cursor = {"offset": next_offset} if next_offset < len(rows) else None
    return page, next_cursor
