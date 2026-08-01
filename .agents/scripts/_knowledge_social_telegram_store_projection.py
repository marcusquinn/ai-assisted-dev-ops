#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Telegram projection filtering and full-text refresh."""

from __future__ import annotations

import sqlite3
from typing import Any

from _knowledge_social_telegram_contract import PROVIDER, ParsedTelegramBatch
from knowledge_social_store import SocialStoreError


def _previous_offset(database: sqlite3.Connection, parsed: ParsedTelegramBatch) -> int:
    previous = database.execute(
        "SELECT cursor FROM sync_cursors WHERE connection_id=? AND stream=?",
        (parsed.archive["connection_id"], parsed.stream),
    ).fetchone()
    return int(previous["cursor"]) if previous and previous["cursor"] else 0


def _future_sequences(update_ids: tuple[int, ...], previous: int) -> list[int]:
    future = [value for value in update_ids if value >= previous]
    expected = previous if previous else (future[0] if future else 0)
    for value in future:
        if value != expected:
            raise SocialStoreError(
                "Telegram fan-out sequence has a gap; prior cursor was preserved"
            )
        expected += 1
    return future


def _record_sequence(record: dict[str, Any]) -> Any:
    return record.get("provider_json", {}).get("fanout_sequence")


def _keep_account(
    record: dict[str, Any], retained: set[int], advances: bool
) -> bool:
    source = record.get("provider_json", {}).get("source")
    return (advances and source == "telegram_bot_api_identity") or (
        _record_sequence(record) in retained
    )


def _filter_projection(
    parsed: ParsedTelegramBatch, retained: set[int], advances: bool
) -> None:
    parsed.archive["accounts"] = [
        record
        for record in parsed.archive["accounts"]
        if _keep_account(record, retained, advances)
    ]
    for key in ("objects", "activities"):
        parsed.archive[key] = [
            record for record in parsed.archive[key] if _record_sequence(record) in retained
        ]
    parsed.archive["media"] = [
        record for record in parsed.archive["media"] if record.get("_fanout_sequence") in retained
    ]


def validate_and_filter_updates(
    database: sqlite3.Connection, parsed: ParsedTelegramBatch
) -> tuple[int, int, bool]:
    """Require contiguous owner sequences and remove stale projections."""
    if parsed.stream != "bot_updates":
        return 0, parsed.normalized_items, True
    previous = _previous_offset(database, parsed)
    future = _future_sequences(parsed.update_ids, previous)
    advances = previous == 0 or bool(future)
    retained = set(future) if previous else set(parsed.update_ids)
    _filter_projection(parsed, retained, advances)
    effective_count = sum(
        len(parsed.archive[key]) for key in ("accounts", "objects", "activities", "media")
    )
    next_offset = max(previous, (future[-1] + 1) if future else previous)
    return next_offset, effective_count, advances


def refresh_fts(database: sqlite3.Connection, parsed: ParsedTelegramBatch) -> None:
    for record in parsed.archive["objects"]:
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
