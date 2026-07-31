#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# SPDX-FileCopyrightText: 2025-2026 Marcus Quinn
"""Import safe WhatsApp exports or verified official business webhooks."""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

from _knowledge_social_lease import (
    RunLease,
    RunLeaseRequest,
    acquire_run_lease,
    fail_active_run,
    release_run_lease,
)
from _knowledge_social_whatsapp import persist_batch
from _knowledge_social_whatsapp_export import ExportRequest, FORMAT_SPECS, parse_export
from _knowledge_social_whatsapp_export_archive import _read_regular
from _knowledge_social_whatsapp_webhook import (
    MAX_WEBHOOK_BYTES,
    WebhookRequest,
    parse_business_webhook,
)
from knowledge_corpus_catalog import DEFAULT_ALIAS, resolve
from knowledge_corpus_context import CatalogError
from knowledge_social_store import SocialStoreError, validate_root

DEFAULT_MAX_BYTES = 128 * 1024 * 1024
DEFAULT_MAX_ITEMS = 50_000


def _positive_int(value: str) -> int:
    try:
        parsed = int(value)
    except ValueError as error:
        raise argparse.ArgumentTypeError("must be an integer") from error
    if parsed < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return parsed


def _common(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--connection-id", required=True)
    parser.add_argument("--observed-at", required=True, help="ISO-8601 time with timezone")
    parser.add_argument("--base", type=Path)
    parser.add_argument("--alias", default=DEFAULT_ALIAS)
    parser.add_argument("--collector-id", default="whatsapp_ingest")
    parser.add_argument("--lease-seconds", type=_positive_int, default=300)
    parser.add_argument("--dry-run", action="store_true")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    export = commands.add_parser("export", help="parse a user-authorized chat export")
    _common(export)
    export.add_argument("--archive", type=Path, required=True)
    export.add_argument("--conversation-id", required=True)
    export.add_argument("--format", dest="format_name", choices=sorted(FORMAT_SPECS), required=True)
    export.add_argument("--timezone", required=True, help="UTC or explicit +/-HH:MM offset")
    export.add_argument("--max-bytes", type=_positive_int, default=DEFAULT_MAX_BYTES)
    export.add_argument("--max-items", type=_positive_int, default=DEFAULT_MAX_ITEMS)
    export.add_argument("--max-seconds", type=_positive_int, default=30)
    webhook = commands.add_parser("webhook", help="verify an official Business Platform webhook")
    _common(webhook)
    webhook.add_argument("--payload", type=Path, required=True)
    webhook.add_argument("--signature-env", default="WHATSAPP_WEBHOOK_SIGNATURE")
    webhook.add_argument("--app-secret-env", default="WHATSAPP_APP_SECRET")
    webhook.add_argument("--waba-id", required=True)
    webhook.add_argument("--phone-number-id", required=True)
    args = parser.parse_args()
    if args.lease_seconds > 86_400:
        parser.error("--lease-seconds cannot exceed 86400")
    if args.command == "export" and (
        args.max_bytes > 512 * 1024 * 1024
        or args.max_items > 1_000_000
        or args.max_seconds > 300
    ):
        parser.error("WhatsApp export budget exceeds the hard limit")
    return args


def _parse_source(args: argparse.Namespace):
    if args.command == "export":
        request = ExportRequest(
            args.archive,
            args.connection_id,
            args.conversation_id,
            args.format_name,
            args.timezone,
            args.observed_at,
            args.max_bytes,
            args.max_items,
            args.max_seconds,
        )
        return parse_export(request)
    secret = os.environ.get(args.app_secret_env)
    if secret is None:
        raise SocialStoreError("WhatsApp webhook app secret environment variable is unavailable")
    signature = os.environ.get(args.signature_env)
    if signature is None:
        raise SocialStoreError("WhatsApp webhook signature environment variable is unavailable")
    payload = _read_regular(args.payload, MAX_WEBHOOK_BYTES)
    parsed = parse_business_webhook(WebhookRequest(
        payload, signature, secret.encode("utf-8"), args.connection_id,
        args.waba_id, args.phone_number_id, args.observed_at,
    ))
    return parsed, payload


def _summary(parsed, *, dry_run: bool) -> dict[str, object]:
    archive = parsed.archive
    return {
        "accounts": len(archive["accounts"]),
        "activities": len(archive["activities"]),
        "coverage": len(archive["coverage"]),
        "dry_run": dry_run,
        "media": len(archive["media"]),
        "objects": len(archive["objects"]),
        "raw_sha256": parsed.raw_sha256,
        "status": "planned" if dry_run else "complete",
        "stream": parsed.stream,
    }


def _release_safely(root: Path, lease: RunLease | None) -> None:
    if lease is None:
        return
    try:
        release_run_lease(root, lease)
    except SocialStoreError:
        return


def main() -> int:
    args = parse_args()
    lease: RunLease | None = None
    root: Path | None = None
    try:
        parsed, payload = _parse_source(args)
        if args.dry_run:
            print(json.dumps(_summary(parsed, dry_run=True), sort_keys=True))
            return 0
        base = args.base or Path.home() / ".aidevops" / ".agent-workspace" / "knowledge"
        root = validate_root(resolve(base, args.alias, "knowledge.write"))
        lease = acquire_run_lease(
            root,
            RunLeaseRequest(
                args.connection_id,
                parsed.stream,
                args.collector_id,
                "sync",
                args.lease_seconds,
                parsed.manifest_sha256,
            ),
        )
        result = persist_batch(root, parsed, payload, lease)
        _release_safely(root, lease)
        lease = None
        print(json.dumps({**_summary(parsed, dry_run=False), **result}, sort_keys=True))
        return 0
    except (CatalogError, OSError, SocialStoreError, ValueError) as error:
        if root is not None and lease is not None:
            try:
                fail_active_run(root, lease, "whatsapp_ingest_failure")
            except SocialStoreError:
                pass
            _release_safely(root, lease)
        print(f"ERROR: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
