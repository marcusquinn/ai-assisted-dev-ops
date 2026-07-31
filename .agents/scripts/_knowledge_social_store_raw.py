#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Validation and loading of immutable social raw evidence."""

from __future__ import annotations

import gzip
import hashlib
import json
import os
import re
import sqlite3
from pathlib import Path

from _knowledge_social_store_support import (
    COLLECTOR_ENVELOPE_FIELDS,
    INVALID_RAW_METADATA,
    INVALID_RAW_PATH,
    MAX_RAW_BATCH_BYTES,
    OPAQUE_ID,
    SHA256_HEX,
    SocialStoreError,
)
from knowledge_corpus_context import (
    CatalogError,
    validate_directory,
    validate_private_file,
)


def store_root(connection: sqlite3.Connection) -> Path:
    database_rows = connection.execute("PRAGMA database_list").fetchall()
    database_file = next(
        (str(row["file"]) for row in database_rows if row["name"] == "main"), ""
    )
    if not database_file:
        raise SocialStoreError("legacy social data requires a file-backed store")
    return Path(database_file).resolve(strict=True).parent.parent


def _validated_raw_ref(blob_ref: str) -> tuple[Path, str, str, str]:
    relative = Path(blob_ref)
    if relative.is_absolute():
        raise SocialStoreError(INVALID_RAW_PATH)
    if len(relative.parts) != 6:
        raise SocialStoreError(INVALID_RAW_PATH)
    prefix, provider, connection_id, filename = (
        relative.parts[:3],
        relative.parts[3],
        relative.parts[4],
        relative.parts[5],
    )
    if prefix != ("sources", "social", "raw"):
        raise SocialStoreError(INVALID_RAW_PATH)
    if OPAQUE_ID.fullmatch(provider) is None:
        raise SocialStoreError(INVALID_RAW_PATH)
    if OPAQUE_ID.fullmatch(connection_id) is None:
        raise SocialStoreError(INVALID_RAW_PATH)
    if re.fullmatch(r"[0-9a-f]{64}\.json\.gz", filename) is None:
        raise SocialStoreError(INVALID_RAW_PATH)
    return relative, provider, connection_id, filename


def _read_private_raw_file(root: Path, relative: Path) -> bytes:
    raw_root = root / "sources" / "social" / "raw"
    path = root / relative
    try:
        resolved = path.resolve(strict=True)
        if resolved != Path(os.path.abspath(path)):
            raise SocialStoreError("legacy social raw evidence contains a symlink")
        resolved.relative_to(raw_root.resolve(strict=True))
        validate_directory(path.parent.parent, "social provider directory", repair=False)
        validate_directory(path.parent, "social connection directory", repair=False)
        validate_private_file(path, "legacy social raw evidence", repair=False)
        with gzip.open(path, "rb") as source:
            payload = source.read(MAX_RAW_BATCH_BYTES + 1)
    except (CatalogError, OSError, EOFError, ValueError) as error:
        raise SocialStoreError("legacy social raw evidence is unsafe") from error
    if len(payload) > MAX_RAW_BATCH_BYTES:
        raise SocialStoreError("legacy social raw evidence exceeds the size limit")
    return payload


def read_raw_payload(
    connection: sqlite3.Connection, blob_ref: str
) -> tuple[bytes, str, str, str]:
    relative, provider, connection_id, filename = _validated_raw_ref(blob_ref)
    payload = _read_private_raw_file(store_root(connection), relative)
    digest = hashlib.sha256(payload).hexdigest()
    if filename != f"{digest}.json.gz":
        raise SocialStoreError("legacy social raw evidence hash does not match")
    return payload, digest, provider, connection_id


def _decoded_collector_envelope(payload: bytes) -> dict[str, object] | None:
    try:
        envelope = json.loads(payload)
    except (UnicodeDecodeError, json.JSONDecodeError):
        return None
    if not isinstance(envelope, dict):
        return None
    if set(envelope) != COLLECTOR_ENVELOPE_FIELDS:
        return None
    return envelope


def _validate_collector_scope(
    envelope: dict[str, object], payload: bytes, provider: str, connection_id: str
) -> None:
    canonical = json.dumps(
        envelope, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if canonical != payload:
        raise SocialStoreError(INVALID_RAW_METADATA)
    if envelope["provider"] != provider:
        raise SocialStoreError(INVALID_RAW_METADATA)
    if envelope["connection_id"] != connection_id:
        raise SocialStoreError(INVALID_RAW_METADATA)


def _validate_collector_fields(envelope: dict[str, object]) -> None:
    for field in ("stream", "observed_at"):
        value = envelope[field]
        if not isinstance(value, str) or not value:
            raise SocialStoreError(INVALID_RAW_METADATA)
    for field in ("request_hash", "response_sha256"):
        value = envelope[field]
        if not isinstance(value, str) or SHA256_HEX.fullmatch(value) is None:
            raise SocialStoreError(INVALID_RAW_METADATA)


def _validate_collector_response(envelope: dict[str, object]) -> None:
    response_hash = str(envelope["response_sha256"])
    response = json.dumps(
        envelope["response"], ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    if hashlib.sha256(response).hexdigest() != response_hash:
        raise SocialStoreError("legacy social response hash does not match")


def _validate_collector_envelope(
    envelope: dict[str, object], payload: bytes, provider: str, connection_id: str
) -> None:
    _validate_collector_scope(envelope, payload, provider, connection_id)
    _validate_collector_fields(envelope)
    _validate_collector_response(envelope)


def collector_envelope(
    payload: bytes, provider: str, connection_id: str, *, required: bool
) -> dict[str, object] | None:
    envelope = _decoded_collector_envelope(payload)
    if envelope is None:
        if not required:
            return None
        raise SocialStoreError(INVALID_RAW_METADATA)
    _validate_collector_envelope(envelope, payload, provider, connection_id)
    return envelope
