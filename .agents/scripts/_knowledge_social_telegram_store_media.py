#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Immutable media persistence for Telegram evidence."""

from __future__ import annotations

import hashlib
import os
import tempfile
from pathlib import Path

from _knowledge_social_telegram_contract import (
    PROVIDER,
    ParsedTelegramBatch,
    TelegramMediaPayload,
    read_bounded_path,
)
from knowledge_social_store import SocialStoreError, private_directory


def fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _verify_blob(path: Path, payload: bytes, digest: str) -> None:
    existing = read_bounded_path(path, len(payload), "stored media blob")
    if hashlib.sha256(existing).hexdigest() != digest:
        raise SocialStoreError("Telegram immutable media blob conflicts with stored bytes")


def _create_blob(path: Path, payload: bytes, digest: str) -> bool:
    descriptor, temporary_name = tempfile.mkstemp(prefix=".telegram-media-", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as target:
            descriptor = -1
            target.write(payload)
            target.flush()
            os.fsync(target.fileno())
        try:
            os.link(temporary, path)
            fsync_directory(path.parent)
            return True
        except FileExistsError:
            _verify_blob(path, payload, digest)
            return False
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        temporary.unlink(missing_ok=True)


def _write_blob(
    root: Path, directory: Path, media: TelegramMediaPayload
) -> tuple[str, Path | None]:
    digest = hashlib.sha256(media.payload).hexdigest()
    path = directory / digest
    if path.exists():
        _verify_blob(path, media.payload, digest)
        created = False
    else:
        created = _create_blob(path, media.payload, digest)
    relative = path.relative_to(root).as_posix()
    return relative, path if created else None


def write_media(
    root: Path, parsed: ParsedTelegramBatch
) -> tuple[dict[str, str], list[Path]]:
    refs: dict[str, str] = {}
    created: list[Path] = []
    if not parsed.media_payloads:
        return refs, created
    directory = private_directory(
        root, Path("sources") / "social" / "media" / PROVIDER / parsed.archive["connection_id"]
    )
    try:
        for media in parsed.media_payloads:
            relative, created_path = _write_blob(root, directory, media)
            refs[media.remote_id] = relative
            if created_path is not None:
                created.append(created_path)
        return refs, created
    except Exception:
        remove_created(created)
        raise


def remove_created(paths: list[Path]) -> None:
    for path in reversed(paths):
        try:
            path.unlink(missing_ok=True)
            fsync_directory(path.parent)
        except OSError:
            continue
