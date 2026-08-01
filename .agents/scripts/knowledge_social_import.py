#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Import provider-neutral archives into a private social corpus."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_source_contract import (
    SourceContractError,
    reject_credentials as reject_source_credentials,
)
from knowledge_social_store import (
    SCHEMA_VERSION,
    SocialStoreError,
    connect,
    connect_read_only,
    migrate,
    raw_evidence_transaction,
    rebuild_fts,
    require_schema,
    validate_opaque,
    validate_root,
)

OBJECT_UPSERT = """INSERT INTO objects(
    provider,object_type,remote_id,account_remote_id,text_content,created_at,
    observed_at,evidence_class,provider_json,batch_id) VALUES(?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(provider,object_type,remote_id) DO UPDATE SET
    account_remote_id=excluded.account_remote_id,text_content=excluded.text_content,
    created_at=excluded.created_at,observed_at=excluded.observed_at,
    evidence_class=excluded.evidence_class,provider_json=excluded.provider_json,
    batch_id=excluded.batch_id"""
ACTIVITY_UPSERT = """INSERT INTO activities(
    provider,activity_type,remote_id,actor_remote_id,object_remote_id,occurred_at,
    observed_at,state,provider_json,batch_id) VALUES(?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(provider,activity_type,remote_id) DO UPDATE SET
    actor_remote_id=excluded.actor_remote_id,object_remote_id=excluded.object_remote_id,
    occurred_at=excluded.occurred_at,
    observed_at=excluded.observed_at,state=excluded.state,
    provider_json=excluded.provider_json,batch_id=excluded.batch_id"""


def canonical_json(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def required_text(record: dict[str, Any], key: str) -> str:
    value = record.get(key)
    if not isinstance(value, str) or not value:
        raise SocialStoreError(f"archive record requires non-empty {key}")
    return value


def optional_text(record: dict[str, Any], key: str) -> str | None:
    value = record.get(key)
    if value is None:
        return None
    if not isinstance(value, str):
        raise SocialStoreError(f"archive record {key} must be text or null")
    return value


def record_list(archive: dict[str, Any], key: str) -> list[dict[str, Any]]:
    value = archive.get(key, [])
    if not isinstance(value, list) or any(not isinstance(item, dict) for item in value):
        raise SocialStoreError(f"archive {key} must be an array of objects")
    return value


def reject_credentials(value: Any) -> None:
    """Preserve the social-store error boundary around the shared rejection rule."""
    try:
        reject_source_credentials(value)
    except SourceContractError as error:
        raise SocialStoreError("archive contains forbidden credential material") from error


def load_archive(path: Path) -> tuple[dict[str, Any], bytes]:
    if path.is_symlink() or not path.is_file():
        raise SocialStoreError("archive must be a regular non-symlink file")
    try:
        parsed = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SocialStoreError("archive is not valid UTF-8 JSON") from error
    if not isinstance(parsed, dict):
        raise SocialStoreError("archive root must be an object")
    reject_credentials(parsed)
    payload = canonical_json(parsed).encode("utf-8")
    return parsed, payload


def upsert_connection(connection: Any, archive: dict[str, Any], provider: str, connection_id: str) -> None:
    remote_account_id = required_text(archive, "remote_account_id")
    enabled_streams = archive.get("enabled_streams", [])
    policy = archive.get("policy", {})
    if not isinstance(enabled_streams, list) or not isinstance(policy, dict):
        raise SocialStoreError("enabled_streams and policy have invalid types")
    connection.execute(
        """INSERT INTO connections(
            connection_id,provider,remote_account_id,auth_profile_ref,enabled_streams,policy_json)
           VALUES(?,?,?,?,?,?)
           ON CONFLICT(connection_id) DO UPDATE SET
             provider=excluded.provider,remote_account_id=excluded.remote_account_id,
             enabled_streams=excluded.enabled_streams,policy_json=excluded.policy_json""",
        (connection_id, provider, remote_account_id, None, canonical_json(enabled_streams), canonical_json(policy)),
    )


def import_accounts(connection: Any, archive: dict[str, Any], provider: str) -> None:
    for record in record_list(archive, "accounts"):
        connection.execute(
            """INSERT INTO accounts(provider,remote_id,handle,display_name,observed_at,provider_json)
               VALUES(?,?,?,?,?,?) ON CONFLICT(provider,remote_id) DO UPDATE SET
               handle=excluded.handle,display_name=excluded.display_name,
               observed_at=excluded.observed_at,provider_json=excluded.provider_json""",
            (provider, required_text(record, "remote_id"), optional_text(record, "handle"),
             optional_text(record, "display_name"), required_text(record, "observed_at"),
             canonical_json(record.get("provider_json", {}))),
        )


def import_objects(connection: Any, archive: dict[str, Any], provider: str, batch_id: str) -> None:
    for record in record_list(archive, "objects"):
        connection.execute(
            OBJECT_UPSERT,
            (provider, required_text(record, "object_type"), required_text(record, "remote_id"),
             optional_text(record, "account_remote_id"), optional_text(record, "text"),
             optional_text(record, "created_at"), required_text(record, "observed_at"),
             required_text(record, "evidence_class"), canonical_json(record.get("provider_json", {})), batch_id),
        )


def import_activities(connection: Any, archive: dict[str, Any], provider: str, batch_id: str) -> None:
    for record in record_list(archive, "activities"):
        connection.execute(
            ACTIVITY_UPSERT,
            (provider, required_text(record, "activity_type"), required_text(record, "remote_id"),
             required_text(record, "actor_remote_id"), optional_text(record, "object_remote_id"),
             optional_text(record, "occurred_at"), required_text(record, "observed_at"),
             required_text(record, "state"), canonical_json(record.get("provider_json", {})), batch_id),
        )


def import_media(connection: Any, archive: dict[str, Any], provider: str, batch_id: str) -> None:
    for record in record_list(archive, "media"):
        byte_size = record.get("byte_size")
        if byte_size is not None and (not isinstance(byte_size, int) or byte_size < 0):
            raise SocialStoreError("media byte_size must be a non-negative integer")
        connection.execute(
            """INSERT INTO media(
                provider,remote_id,object_remote_id,content_sha256,mime_type,byte_size,
                blob_ref,hydration_state,batch_id) VALUES(?,?,?,?,?,?,?,?,?)
               ON CONFLICT(provider,remote_id) DO UPDATE SET
                object_remote_id=excluded.object_remote_id,content_sha256=excluded.content_sha256,
                mime_type=excluded.mime_type,byte_size=excluded.byte_size,blob_ref=excluded.blob_ref,
                hydration_state=excluded.hydration_state,batch_id=excluded.batch_id""",
            (provider, required_text(record, "remote_id"), optional_text(record, "object_remote_id"),
             optional_text(record, "content_sha256"), optional_text(record, "mime_type"), byte_size,
             optional_text(record, "blob_ref"), required_text(record, "hydration_state"), batch_id),
        )


def import_coverage(connection: Any, archive: dict[str, Any], provider: str, connection_id: str, batch_id: str) -> None:
    for record in record_list(archive, "coverage"):
        exhausted = record.get("cursor_exhausted", False)
        if not isinstance(exhausted, bool):
            raise SocialStoreError("coverage cursor_exhausted must be boolean")
        connection.execute(
            """INSERT INTO coverage_records(
                provider,connection_id,stream,earliest_at,latest_at,cursor_exhausted,
                retention_limit,unavailable_reason,status,batch_id,observed_at)
               VALUES(?,?,?,?,?,?,?,?,?,?,?) ON CONFLICT(provider,connection_id,stream) DO UPDATE SET
                earliest_at=excluded.earliest_at,latest_at=excluded.latest_at,
                cursor_exhausted=excluded.cursor_exhausted,retention_limit=excluded.retention_limit,
                unavailable_reason=excluded.unavailable_reason,status=excluded.status,
                batch_id=excluded.batch_id,observed_at=excluded.observed_at""",
            (provider, connection_id, required_text(record, "stream"), optional_text(record, "earliest_at"),
             optional_text(record, "latest_at"), int(exhausted), optional_text(record, "retention_limit"),
             optional_text(record, "unavailable_reason"), required_text(record, "status"), batch_id,
             required_text(record, "observed_at")),
        )


def import_archive(root: Path, archive_path: Path) -> dict[str, Any]:
    archive, payload = load_archive(archive_path)
    return import_archive_payload(root, archive, payload)


def import_archive_payload(
    root: Path, archive: dict[str, Any], payload: bytes
) -> dict[str, Any]:
    """Import an already-validated in-memory archive without plaintext staging."""
    reject_credentials(archive)
    if payload != canonical_json(archive).encode("utf-8"):
        raise SocialStoreError("archive payload is not canonical")
    provider = validate_opaque(required_text(archive, "provider"), "provider")
    connection_id = validate_opaque(required_text(archive, "connection_id"), "connection_id")
    completed_at = required_text(archive, "exported_at")
    database = connect(root)
    try:
        migrate(database)
        with raw_evidence_transaction(database, root) as transaction:
            batch_id, blob_ref = transaction.write(
                provider, connection_id, payload
            )
            upsert_connection(database, archive, provider, connection_id)
            import_accounts(database, archive, provider)
            import_objects(database, archive, provider, batch_id)
            import_activities(database, archive, provider, batch_id)
            import_media(database, archive, provider, batch_id)
            import_coverage(database, archive, provider, connection_id, batch_id)
            resource_count = sum(
                len(record_list(archive, key))
                for key in ("accounts", "objects", "activities", "media")
            )
            database.execute(
                """INSERT OR IGNORE INTO fetch_batches(
                    batch_id,provider,connection_id,stream,response_hash,blob_ref,
                    resource_count,completed_at,terminal_status) VALUES(?,?,?,?,?,?,?,?,?)""",
                (
                    batch_id,
                    provider,
                    connection_id,
                    "archive",
                    batch_id,
                    blob_ref,
                    resource_count,
                    completed_at,
                    "success",
                ),
            )
        rebuild_fts(database)
        return {"batch_id": batch_id, "resource_count": resource_count, "blob_ref": blob_ref}
    finally:
        database.close()


def provision(root: Path) -> None:
    database = connect(root)
    try:
        migrate(database)
    finally:
        database.close()


def rebuild(root: Path) -> None:
    database = connect(root)
    try:
        migrate(database)
        rebuild_fts(database)
    finally:
        database.close()


def coverage(root: Path) -> list[dict[str, Any]]:
    database = connect_read_only(root)
    try:
        require_schema(database)
        rows = database.execute(
            """SELECT provider,connection_id,stream,earliest_at,latest_at,cursor_exhausted,
                      retention_limit,unavailable_reason,status,batch_id,observed_at
                 FROM coverage_records ORDER BY provider,connection_id,stream"""
        ).fetchall()
        return [dict(row) for row in rows]
    finally:
        database.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("provision", "import-archive", "rebuild", "coverage"))
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--archive", type=Path)
    args = parser.parse_args()
    if args.command == "import-archive" and args.archive is None:
        parser.error("import-archive requires --archive")
    if args.command != "import-archive" and args.archive is not None:
        parser.error("--archive is only valid with import-archive")
    return args


def main() -> int:
    args = parse_args()
    try:
        capability = "knowledge.read" if args.command == "coverage" else "knowledge.write"
        base = args.base if args.base is not None else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        root = validate_root(resolve(base, args.alias, capability))
        if args.command == "provision":
            provision(root)
            result: Any = {"schema_version": SCHEMA_VERSION}
        elif args.command == "import-archive":
            result = import_archive(root, args.archive)
        elif args.command == "rebuild":
            rebuild(root)
            result = {"rebuilt": True}
        else:
            result = coverage(root)
        print(json.dumps(result, sort_keys=True))
        return 0
    except (CatalogError, OSError, SocialStoreError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
