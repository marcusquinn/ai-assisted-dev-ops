#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Store timestamp-ordered Slack records without regressing newer state."""

from __future__ import annotations

import json
import sqlite3
from typing import Any

from _knowledge_social_collect import CollectionContext, SuccessfulPage
from _knowledge_social_slack import PROVIDER
from _knowledge_social_slack_evidence_guard import reject_slack_credentials
from _knowledge_social_slack_normalize import IMMUTABLE_POLICY_FIELDS
from knowledge_social_import import (
    ACTIVITY_UPSERT,
    OBJECT_UPSERT,
    canonical_json,
    import_media,
    optional_text,
    record_list,
    required_text,
    upsert_connection,
)
from knowledge_social_store import SocialStoreError

ORDERED_ACCOUNT_UPSERT = (
    "INSERT INTO accounts(provider,remote_id,handle,display_name,observed_at,provider_json) "
    "VALUES(?,?,?,?,?,?) ON CONFLICT(provider,remote_id) DO UPDATE SET "
    "handle=excluded.handle,display_name=excluded.display_name,"
    "observed_at=excluded.observed_at,provider_json=excluded.provider_json "
    "WHERE excluded.observed_at > accounts.observed_at OR "
    "(excluded.observed_at = accounts.observed_at AND "
    "(excluded.handle IS NOT NULL,COALESCE(excluded.handle,''),"
    "excluded.display_name IS NOT NULL,COALESCE(excluded.display_name,''),"
    "excluded.provider_json) > "
    "(accounts.handle IS NOT NULL,COALESCE(accounts.handle,''),"
    "accounts.display_name IS NOT NULL,COALESCE(accounts.display_name,''),"
    "accounts.provider_json))"
)
ORDERED_OBJECT_UPSERT = (
    f"{OBJECT_UPSERT} WHERE excluded.observed_at > objects.observed_at OR "
    "(excluded.observed_at = objects.observed_at "
    "AND excluded.batch_id > objects.batch_id)"
)
ORDERED_ACTIVITY_UPSERT = (
    f"{ACTIVITY_UPSERT} WHERE excluded.observed_at > activities.observed_at OR "
    "(excluded.observed_at = activities.observed_at "
    "AND excluded.batch_id > activities.batch_id)"
)
ORDERED_COVERAGE_UPSERT = (
    "INSERT INTO coverage_records(provider,connection_id,stream,earliest_at,latest_at,"
    "cursor_exhausted,retention_limit,unavailable_reason,status,batch_id,observed_at) "
    "VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,connection_id,stream) DO UPDATE SET "
    "earliest_at=excluded.earliest_at,latest_at=excluded.latest_at,"
    "cursor_exhausted=excluded.cursor_exhausted,retention_limit=excluded.retention_limit,"
    "unavailable_reason=excluded.unavailable_reason,status=excluded.status,"
    "batch_id=excluded.batch_id,observed_at=excluded.observed_at "
    "WHERE excluded.observed_at > coverage_records.observed_at OR "
    "(excluded.observed_at = coverage_records.observed_at "
    "AND excluded.batch_id > coverage_records.batch_id)"
)


def _stored_json(value: str, expected: type[Any], field: str) -> Any:
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError as error:
        raise SocialStoreError(f"stored Slack {field} is invalid") from error
    if not isinstance(parsed, expected):
        raise SocialStoreError(f"stored Slack {field} is invalid")
    reject_slack_credentials(parsed)
    return parsed


def merge_connection_state(
    database: sqlite3.Connection, archive: dict[str, Any]
) -> dict[str, Any]:
    """Merge mutable connection metadata while enforcing immutable identity fields."""
    connection_id = archive["connection_id"]
    row = database.execute(
        "SELECT provider,remote_account_id,enabled_streams,policy_json "
        "FROM connections WHERE connection_id=?",
        (connection_id,),
    ).fetchone()
    if row is None:
        return archive
    binding = (row["provider"], row["remote_account_id"])
    expected_binding = (PROVIDER, archive["remote_account_id"])
    if binding != expected_binding:
        raise SocialStoreError("Slack connection is already bound to another account")
    policy = _stored_json(row["policy_json"], dict, "connection policy")
    streams = _stored_json(row["enabled_streams"], list, "enabled streams")
    if any(not isinstance(stream, str) for stream in streams):
        raise SocialStoreError("stored Slack enabled streams are invalid")
    incoming_policy = archive.get("policy")
    if not isinstance(incoming_policy, dict):
        raise SocialStoreError("Slack connection policy is invalid")
    if any(field not in policy for field in IMMUTABLE_POLICY_FIELDS):
        raise SocialStoreError("stored Slack identity policy is incomplete")
    changed_identity = any(
        policy[field] != incoming_policy.get(field)
        for field in IMMUTABLE_POLICY_FIELDS
    )
    if changed_identity:
        raise SocialStoreError("Slack connection identity policy was rebound")
    latest_row = database.execute(
        "SELECT max(completed_at) FROM fetch_batches "
        "WHERE provider=? AND connection_id=?",
        (PROVIDER, connection_id),
    ).fetchone()
    latest = latest_row[0] if latest_row is not None else None
    merged_policy = dict(policy)
    if latest is None or archive["exported_at"] > latest:
        previous_scopes = policy.get("slack_read_scopes")
        merged_policy.update(incoming_policy)
        if not incoming_policy.get("slack_read_scopes") and previous_scopes:
            merged_policy["slack_read_scopes"] = previous_scopes
    merged_streams = list(streams)
    for stream in archive.get("enabled_streams", []):
        if not isinstance(stream, str):
            raise SocialStoreError("Slack enabled stream is invalid")
        if stream not in merged_streams:
            merged_streams.append(stream)
    return {**archive, "enabled_streams": merged_streams, "policy": merged_policy}


def _account_values(record: dict[str, Any]) -> tuple[Any, ...]:
    return (
        PROVIDER,
        required_text(record, "remote_id"),
        optional_text(record, "handle"),
        optional_text(record, "display_name"),
        required_text(record, "observed_at"),
        canonical_json(record.get("provider_json", {})),
    )


def _object_values(record: dict[str, Any], batch_id: str) -> tuple[Any, ...]:
    return (
        PROVIDER,
        required_text(record, "object_type"),
        required_text(record, "remote_id"),
        optional_text(record, "account_remote_id"),
        optional_text(record, "text"),
        optional_text(record, "created_at"),
        required_text(record, "observed_at"),
        required_text(record, "evidence_class"),
        canonical_json(record.get("provider_json", {})),
        batch_id,
    )


def _activity_values(record: dict[str, Any], batch_id: str) -> tuple[Any, ...]:
    return (
        PROVIDER,
        required_text(record, "activity_type"),
        required_text(record, "remote_id"),
        required_text(record, "actor_remote_id"),
        optional_text(record, "object_remote_id"),
        optional_text(record, "occurred_at"),
        required_text(record, "observed_at"),
        required_text(record, "state"),
        canonical_json(record.get("provider_json", {})),
        batch_id,
    )


def _coverage_values(
    record: dict[str, Any], connection_id: str, batch_id: str
) -> tuple[Any, ...]:
    exhausted = record.get("cursor_exhausted", False)
    if not isinstance(exhausted, bool):
        raise SocialStoreError("coverage cursor_exhausted must be boolean")
    return (
        PROVIDER,
        connection_id,
        required_text(record, "stream"),
        optional_text(record, "earliest_at"),
        optional_text(record, "latest_at"),
        int(exhausted),
        optional_text(record, "retention_limit"),
        optional_text(record, "unavailable_reason"),
        required_text(record, "status"),
        batch_id,
        required_text(record, "observed_at"),
    )


def _import_media_ordered(
    database: sqlite3.Connection, archive: dict[str, Any], batch_id: str
) -> None:
    observed_at = required_text(archive, "exported_at")
    accepted: list[dict[str, Any]] = []
    for record in record_list(archive, "media"):
        remote_id = required_text(record, "remote_id")
        row = database.execute(
            "SELECT observed_at,batch_id FROM objects "
            "WHERE provider=? AND object_type='file' AND remote_id=?",
            (PROVIDER, remote_id),
        ).fetchone()
        if row is None or (row["observed_at"], row["batch_id"]) <= (
            observed_at,
            batch_id,
        ):
            accepted.append(record)
    import_media(database, {**archive, "media": accepted}, PROVIDER, batch_id)


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


def store_ordered_records(
    database: sqlite3.Connection,
    archive: dict[str, Any],
    batch_id: str,
    connection_id: str,
) -> None:
    """Upsert one normalized Slack archive in evidence timestamp order."""
    upsert_connection(database, archive, PROVIDER, connection_id)
    accounts = (_account_values(row) for row in record_list(archive, "accounts"))
    objects = (
        _object_values(row, batch_id) for row in record_list(archive, "objects")
    )
    activities = (
        _activity_values(row, batch_id) for row in record_list(archive, "activities")
    )
    coverage = (
        _coverage_values(row, connection_id, batch_id)
        for row in record_list(archive, "coverage")
    )
    database.executemany(ORDERED_ACCOUNT_UPSERT, accounts)
    database.executemany(ORDERED_OBJECT_UPSERT, objects)
    database.executemany(ORDERED_ACTIVITY_UPSERT, activities)
    _import_media_ordered(database, archive, batch_id)
    database.executemany(ORDERED_COVERAGE_UPSERT, coverage)
    _refresh_fts(database, archive)


def _page_time_bounds(archive: dict[str, Any]) -> tuple[str | None, str | None]:
    timestamps = [
        value
        for rows, key in (
            (archive["objects"], "created_at"),
            (archive["activities"], "occurred_at"),
        )
        for record in rows
        if isinstance((value := record.get(key)), str) and value
    ]
    if not timestamps:
        return None, None
    return min(timestamps), max(timestamps)


def _update_page_cursor(
    database: sqlite3.Connection,
    context: CollectionContext,
    page: SuccessfulPage,
    observed_at: str,
) -> None:
    database.execute(
        """INSERT INTO sync_cursors(
           connection_id,stream,cursor,watermark,last_success_at,backfill_complete)
           VALUES(?,?,?,?,?,?) ON CONFLICT(connection_id,stream) DO UPDATE SET
           cursor=excluded.cursor,watermark=excluded.watermark,
           last_success_at=excluded.last_success_at,
           backfill_complete=MAX(sync_cursors.backfill_complete,excluded.backfill_complete)
           WHERE excluded.last_success_at >= sync_cursors.last_success_at""",
        (
            context.connection_id,
            context.stream,
            page.checkpoint.next_cursor,
            page.checkpoint.watermark,
            observed_at,
            int(page.complete),
        ),
    )


def _upsert_page_coverage(
    database: sqlite3.Connection,
    context: CollectionContext,
    page: SuccessfulPage,
    archive: dict[str, Any],
    batch_id: str,
) -> None:
    earliest, latest = _page_time_bounds(archive)
    status = page.coverage_status or ("complete" if page.complete else "partial")
    database.execute(
        """INSERT INTO coverage_records(
           provider,connection_id,stream,earliest_at,latest_at,cursor_exhausted,
           retention_limit,unavailable_reason,status,batch_id,observed_at)
           VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,connection_id,stream)
           DO UPDATE SET earliest_at=CASE
             WHEN coverage_records.earliest_at IS NULL THEN excluded.earliest_at
             WHEN excluded.earliest_at IS NULL THEN coverage_records.earliest_at
             WHEN excluded.earliest_at < coverage_records.earliest_at
               THEN excluded.earliest_at ELSE coverage_records.earliest_at END,
           latest_at=CASE
             WHEN coverage_records.latest_at IS NULL THEN excluded.latest_at
             WHEN excluded.latest_at IS NULL THEN coverage_records.latest_at
             WHEN excluded.latest_at > coverage_records.latest_at
               THEN excluded.latest_at ELSE coverage_records.latest_at END,
           cursor_exhausted=excluded.cursor_exhausted,
           retention_limit=excluded.retention_limit,
           unavailable_reason=excluded.unavailable_reason,status=excluded.status,
           batch_id=excluded.batch_id,observed_at=excluded.observed_at
           WHERE excluded.observed_at >= coverage_records.observed_at""",
        (
            PROVIDER,
            context.connection_id,
            context.stream,
            earliest,
            latest,
            int(page.complete),
            page.retention_limit,
            page.unavailable_reason,
            status,
            batch_id,
            archive["exported_at"],
        ),
    )


def update_page_state(
    database: sqlite3.Connection,
    context: CollectionContext,
    page: SuccessfulPage,
    archive: dict[str, Any],
    batch_id: str,
) -> None:
    """Advance one Slack stream cursor and its aggregate coverage monotonically."""
    _update_page_cursor(database, context, page, archive["exported_at"])
    _upsert_page_coverage(database, context, page, archive, batch_id)
