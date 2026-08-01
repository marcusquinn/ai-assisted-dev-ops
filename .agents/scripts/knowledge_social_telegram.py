#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Import bounded Telegram Desktop exports or authorized bot-event fan-out."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any

from _knowledge_social_lease import (
    RunLease,
    RunLeaseRequest,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_telegram_contract import ParsedTelegramBatch, TelegramRequest
from _knowledge_social_telegram_export import parse_telegram_export
from _knowledge_social_telegram_store import persist_telegram_batch
from _knowledge_social_telegram_updates import parse_telegram_updates
from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_store import (
    SocialStoreError,
    connect_read_only,
    require_schema,
    validate_root,
)

DEFAULT_MAX_BYTES = 512 * 1024 * 1024
DEFAULT_MAX_ITEMS = 100_000
DEFAULT_MAX_MEDIA_BYTES = 1024 * 1024 * 1024


def _positive(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    for command in ("import-export", "import-updates"):
        current = subparsers.add_parser(command)
        current.add_argument("--base", type=Path)
        current.add_argument("--alias", default=DEFAULT_ALIAS)
        current.add_argument("--input", required=True, type=Path)
        current.add_argument("--connection-id", required=True)
        current.add_argument("--expected-id", required=True)
        current.add_argument("--allow-chat", action="append", default=[])
        current.add_argument("--observed-at", required=True)
        current.add_argument("--max-bytes", type=_positive, default=DEFAULT_MAX_BYTES)
        current.add_argument("--max-items", type=_positive, default=DEFAULT_MAX_ITEMS)
        current.add_argument(
            "--max-media-bytes", type=_positive, default=DEFAULT_MAX_MEDIA_BYTES
        )
        current.add_argument("--collector-id", default="telegram_collector")
        current.add_argument("--lease-seconds", type=_positive, default=300)
        current.add_argument("--dry-run", action="store_true")
        if command == "import-updates":
            current.add_argument("--owner-id", required=True)
    status = subparsers.add_parser("status")
    status.add_argument("--base", type=Path)
    status.add_argument("--alias", default=DEFAULT_ALIAS)
    status.add_argument("--connection-id", required=True)
    return parser


def _root(args: argparse.Namespace, capability: str) -> Path:
    base = (
        args.base
        if args.base is not None
        else Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
    )
    return validate_root(resolve(base, args.alias, capability))


def _request(args: argparse.Namespace) -> TelegramRequest:
    if args.max_bytes > 1024 * 1024 * 1024:
        raise SocialStoreError("--max-bytes cannot exceed 1073741824")
    if args.max_items > 1_000_000:
        raise SocialStoreError("--max-items cannot exceed 1000000")
    if args.max_media_bytes > 4 * 1024 * 1024 * 1024:
        raise SocialStoreError("--max-media-bytes cannot exceed 4294967296")
    if args.lease_seconds > 86_400:
        raise SocialStoreError("--lease-seconds cannot exceed 86400")
    return TelegramRequest(
        args.input,
        args.connection_id,
        args.expected_id,
        frozenset(args.allow_chat),
        args.observed_at,
        args.max_bytes,
        args.max_items,
        args.max_media_bytes,
        getattr(args, "owner_id", None),
    )


def _status(args: argparse.Namespace) -> dict[str, Any]:
    root = _root(args, "knowledge.read")
    database = connect_read_only(root)
    try:
        require_schema(database)
        connection = database.execute(
            "SELECT provider,enabled_streams FROM connections WHERE connection_id=?",
            (args.connection_id,),
        ).fetchone()
        if connection is None or connection["provider"] != "telegram":
            raise SocialStoreError("Telegram connection was not found")
        cursors = database.execute(
            "SELECT stream,cursor,last_success_at,backfill_complete FROM sync_cursors "
            "WHERE connection_id=? ORDER BY stream",
            (args.connection_id,),
        ).fetchall()
        return {
            "connection_id": args.connection_id,
            "enabled_streams": json.loads(connection["enabled_streams"]),
            "streams": [dict(row) for row in cursors],
        }
    finally:
        database.close()


def _release(root: Path | None, lease: RunLease | None) -> None:
    if root is None or lease is None:
        return
    try:
        release_run_lease(root, lease)
    except SocialStoreError:
        return


def _emit_dry_run(parsed: ParsedTelegramBatch) -> None:
    print(
        json.dumps(
            {
                "normalized_items": parsed.normalized_items,
                "raw_sha256": parsed.raw_sha256,
                "status": "dry-run",
                "stream": parsed.stream,
            },
            sort_keys=True,
        )
    )


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    root: Path | None = None
    lease: RunLease | None = None
    try:
        if args.command == "status":
            print(json.dumps(_status(args), sort_keys=True))
            return 0
        request = _request(args)
        parsed = (
            parse_telegram_export(request)
            if args.command == "import-export"
            else parse_telegram_updates(request)
        )
        if args.dry_run:
            _emit_dry_run(parsed)
            return 0
        root = _root(args, "knowledge.write")
        lease = acquire_run_lease(
            root,
            RunLeaseRequest(
                args.connection_id,
                parsed.stream,
                args.collector_id,
                "sync",
                args.lease_seconds,
                parsed.raw_sha256,
            ),
        )
        result = persist_telegram_batch(root, parsed, lease)
        _release(root, lease)
        lease = None
        print(json.dumps(result, sort_keys=True))
        return 0
    except (CatalogError, OSError, SocialStoreError, ValueError) as error:
        if root is not None and lease is not None:
            try:
                fail_active_run(root, lease, "telegram_validation_or_persistence")
            except SocialStoreError:
                pass
            _release(root, lease)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
